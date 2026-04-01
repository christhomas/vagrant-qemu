require "log4r"

module VagrantPlugins
  module QEMU
    module Action
      class MountVirtioFS
        def initialize(app, env)
          @app = app
          @logger = Log4r::Logger.new("vagrant_qemu::action::mount_virtiofs")
        end

        def call(env)
          machine = env[:machine]

          # Find virtiofs synced folders from config
          virtiofs_folders = machine.config.vm.synced_folders.select do |_id, data|
            data[:type].to_s == "virtiofs" && !data[:disabled]
          end

          if virtiofs_folders.any?
            sorted = virtiofs_folders.sort_by { |_id, data| data[:guestpath] }
            sorted.each_with_index do |(_id, data), i|
              guestpath = data[:guestpath]
              tag = "virtiofs#{i}"

              machine.communicate.sudo("mkdir -p #{guestpath}")
              machine.communicate.sudo("mount -t virtiofs #{tag} #{guestpath}")
              machine.ui.info("Mounted virtiofs #{tag} at #{guestpath}")
            end
          end

          @app.call(env)
        end
      end
    end
  end
end
