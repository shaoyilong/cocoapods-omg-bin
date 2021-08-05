require 'cocoapods-imy-bin/native/podfile'
require 'cocoapods/command/gen'
require 'cocoapods/generate'
require 'cocoapods-imy-bin/helpers/framework_builder'
require 'cocoapods-imy-bin/helpers/library_builder'
require 'cocoapods-imy-bin/helpers/build_helper'
require 'cocoapods-imy-bin/helpers/spec_source_creator'
require 'cocoapods-imy-bin/config/config_builder'
require 'cocoapods-imy-bin/command/bin/lib/lint'
require 'xcodeproj'

module Pod
  class Command
    class Bin < Command
      class Archive < Bin

        @@missing_binary_specs = []

        self.summary = '将组件归档为静态库 .a.'
        self.description = <<-DESC
          将组件归档为静态库 framework，仅支持 iOS 平台
          此静态 framework 不包含依赖组件的 symbol
        DESC

        def self.options
          [
              ['--all-make', '对该组件的依赖库，全部制作为二进制组件'],
              ['--code-dependencies', '使用源码依赖'],
              ['--no-clean', '保留构建中间产物'],
              ['--sources', '私有源地址，多个用分号区分'],
              ['--framework-output', '输出framework文件'],
              ['--no-zip', '不压缩静态库 为 zip'],
              ['--configuration', 'Build the specified configuration (e.g. Debug). Defaults to Release'],
              ['--env', "该组件上传的环境 %w[dev debug_iphoneos release_iphoneos]"]
          ].concat(Pod::Command::Gen.options).concat(super).uniq
        end

        self.arguments = [
          CLAide::Argument.new('NAME.podspec', false)
        ]

        def initialize(argv)
          @env = argv.option('env') || 'dev'
          CBin.config.set_configuration_env(@env)
          UI.warn "====== cocoapods-imy-bin #{CBin::VERSION} 版本 ======== \n "
          UI.warn "======  #{@env} 环境 ======== \n "

          @code_dependencies = argv.flag?('code-dependencies')
          @framework_output = argv.flag?('framework-output', false )
          @clean = argv.flag?('no-clean', false)
          @zip = argv.flag?('zip', true)
          @all_make = argv.flag?('all-make', false )
          @sources = argv.option('sources') || []
          @platform = Platform.new(:ios)

          @config = argv.option('configuration', 'Release')

          @framework_path
          super

          @additional_args = argv.remainder!
          @build_finshed = false
        end

        def run
          # 清除之前的缓存
          CBin::Config::Builder.instance.clean

          @spec = Specification.from_file(spec_file)
          generate_project

          swift_pods_buildsetting

          build_root_spec

          sources_sepc = Array.new
          sources_sepc << @spec
          sources_sepc.concat(build_dependencies) if @all_make

          sources_sepc
        end

        def build_root_spec
          builder = CBin::Build::Helper.new(@spec,
                                            @platform,
                                            @framework_output,
                                            @zip,
                                            @spec,
                                            CBin::Config::Builder.instance.white_pod_list.include?(@spec.name),
                                            @config)
          builder.build
          builder.clean_workspace if @clean && !@all_make
        end

        def build_dependencies
          @build_finshed = true
          #如果没要求，就清空依赖库数据
          sources_sepc = []
          @@missing_binary_specs.uniq.each do |spec|
            next if spec.name.include?('/')
            next if spec.name == @spec.name
            #过滤白名单
            next if CBin::Config::Builder.instance.white_pod_list.include?(spec.name)
            #过滤 git
            if spec.source[:git] && spec.source[:git]
              spec_git = spec.source[:git]
              spec_git_res = false
              CBin::Config::Builder.instance.ignore_git_list.each do |ignore_git|
                spec_git_res = spec_git.include?(ignore_git)
                break if spec_git_res
              end
              next if spec_git_res
            end
            UI.warn "#{spec.name}.podspec 带有 vendored_frameworks 字段，请检查是否有效！！！" if spec.attributes_hash['vendored_frameworks']
            next if spec.attributes_hash['vendored_frameworks'] && @spec.name != spec.name #过滤带有vendored_frameworks的
            next if spec.attributes_hash['ios.vendored_frameworks'] && @spec.name != spec.name #过滤带有vendored_frameworks的
            #获取没有制作二进制版本的spec集合
            sources_sepc << spec
          end

          fail_build_specs = []
          sources_sepc.uniq.each do |spec|
            begin
              builder = CBin::Build::Helper.new(spec,
                                                @platform,
                                                @framework_output,
                                                @zip,
                                                @spec,
                                                false ,
                                                @config)
              builder.build
            rescue Object => exception
              UI.puts exception
              fail_build_specs << spec
            end
          end

          if fail_build_specs.any?
            fail_build_specs.uniq.each do |spec|
              UI.warn "【#{spec.name} | #{spec.version}】组件二进制版本编译失败 ."
            end
          end
          sources_sepc - fail_build_specs
        end

        # 解析器传过来的
        def Archive.missing_binary_specs(missing_binary_specs)
          @@missing_binary_specs = missing_binary_specs unless @build_finshed
        end

        private

        def generate_project
          Podfile.execute_with_bin_plugin do
            Podfile.execute_with_use_binaries(!@code_dependencies) do
                argvs = [
                  "--sources=#{sources_option(@code_dependencies, @sources)}",
                  "--gen-directory=#{CBin::Config::Builder.instance.gen_dir}",
                  '--clean',
                  "--verbose",
                  *@additional_args
                ]

                if File.exist?(Pod::Config.instance.podfile_path)
                  argvs += ['--use-podfile']
                end

                unless CBin::Build::Utils.uses_frameworks?
                  argvs += ['--use-libraries']
                end

                argvs << spec_file if spec_file

                gen = Pod::Command::Gen.new(CLAide::ARGV.new(argvs))
                gen.validate!
                gen.run
            end
          end
        end

        def swift_pods_buildsetting
          # swift_project_link_header
          worksppace_path = File.expand_path("#{CBin::Config::Builder.instance.gen_dir}/#{@spec.name}")
          path = File.join(worksppace_path, "Pods.xcodeproj")
          path = File.join(worksppace_path, "Pods/Pods.xcodeproj") unless File.exist?(path)
          raise Informative,  "#{path} File no exist, please check" unless File.exist?(path)
          project = Xcodeproj::Project.open(path)
          project.build_configurations.each do |x|
            x.build_settings['BUILD_LIBRARY_FOR_DISTRIBUTION'] = true #设置生成swift inter
          end
          project.save
        end

        # def swift_project_link_header
        #   worksppace_path = Pod::Config.instance.installation_root
        #   Dir.chdir(worksppace_path) do
        #     shell_script = <<-'SH'.strip_heredoc
        #          ditto "${DERIVED_SOURCES_DIR}/${PRODUCT_MODULE_NAME}-Swift.h" "${CBin::Config::Builder.instance.gen_dir}"
        #     SH
        #     shell_script
        #
        #     # project = Xcodeproj::Project.open(Dir.glob('*.xcodeproj').first)
        #     # project.build_configurations.each do |x|
        #     #   x.build_settings['DERIVED_SOURCES_DIR']
        #     # end
        #   end
        # end

        def spec_file
          @spec_file ||= begin
                           if @podspec
                             find_spec_file(@podspec)
                           else
                             if code_spec_files.empty?
                               raise Informative, '当前目录下没有找到可用源码 podspec.'
                             end

                             spec_file = code_spec_files.first
                             spec_file
                           end
                         end
        end



      end
    end
  end
end
