require "fileutils"
require "log4r"

module VagrantPlugins
  module QEMU
    class SyncedFolderVirtioFS < Vagrant.plugin("2", :synced_folder)

      def usable?(machine, raise_error = false)
        return false unless machine.provider_name == :qemu

        if find_virtiofsd.nil?
          raise Vagrant::Errors::SyncedFolderUnusable,
            type: "virtiofs",
            reason: "virtiofsd not found. Install with: brew install christhomas/tap/qemu-virtiofs" if raise_error
          return false
        end

        true
      end

      def prepare(machine, folders, opts)
        @logger = Log4r::Logger.new("vagrant_qemu::synced_folder_virtiofs")

        virtiofs_dir = machine.data_dir.join("virtiofs")
        FileUtils.mkdir_p(virtiofs_dir)

        virtiofsd = find_virtiofsd
        memory = machine.provider_config.memory

        extra_args = %W(
          -object memory-backend-memfd,id=mem,size=#{memory},share=on
          -numa node,memdev=mem
        )

        sorted_folders = folders.sort_by { |_id, opts| opts[:guestpath] }
        sorted_folders.each_with_index do |(_id, folder_opts), i|
          hostpath = File.expand_path(folder_opts[:hostpath])
          tag = "virtiofs#{i}"
          socket_path = virtiofs_dir.join("#{tag}.sock").to_s
          pid_file = virtiofs_dir.join("#{tag}.pid").to_s

          # Clean up any stale virtiofsd from a previous run
          cleanup_virtiofsd(pid_file, socket_path)

          # Start virtiofsd
          pid = spawn(
            virtiofsd,
            "--socket-path=#{socket_path}",
            "--shared-dir=#{hostpath}",
            "--sandbox=none",
            [:out, :err] => "/dev/null"
          )
          Process.detach(pid)

          # Wait for socket to appear
          30.times do
            break if File.exist?(socket_path)
            sleep 0.1
          end

          unless File.exist?(socket_path)
            Process.kill("TERM", pid) rescue nil
            raise Vagrant::Errors::VagrantError,
              _key: :virtiofsd_start_failed,
              message: "virtiofsd failed to start for #{hostpath} (socket never appeared)"
          end

          File.write(pid_file, pid.to_s)
          machine.ui.info("virtiofsd started (pid #{pid}) sharing #{hostpath}")

          extra_args += %W(
            -chardev socket,id=char_#{tag},path=#{socket_path}
            -device vhost-user-fs-pci,chardev=char_#{tag},tag=#{tag}
          )
        end

        # Inject QEMU args so StartInstance picks them up
        machine.provider_config.extra_qemu_args += extra_args
      end

      def enable(machine, folders, opts)
        # Mounting happens in MountVirtioFS action after boot,
        # since the guest isn't available when SyncedFolders runs.
      end

      def disable(machine, folders, opts)
        folders.each do |_id, folder_opts|
          guestpath = folder_opts[:guestpath]
          machine.communicate.sudo("umount #{guestpath} 2>/dev/null || true")
        end
      end

      def cleanup(machine, opts)
        virtiofs_dir = machine.data_dir.join("virtiofs")
        return unless virtiofs_dir.directory?

        Dir.glob(virtiofs_dir.join("*.pid").to_s).each do |pid_file|
          sock_file = pid_file.sub(/\.pid$/, ".sock")
          cleanup_virtiofsd(pid_file, sock_file)
        end

        FileUtils.rm_rf(virtiofs_dir)
        machine.ui.info("virtiofsd stopped") if machine.ui
      end

      private

      def find_virtiofsd
        path = `which virtiofsd 2>/dev/null`.strip
        return path unless path.empty?

        %w(
          /opt/homebrew/bin/virtiofsd
          /usr/local/bin/virtiofsd
          /usr/lib/qemu/virtiofsd
          /usr/libexec/virtiofsd
        ).each do |p|
          return p if File.executable?(p)
        end

        nil
      end

      def cleanup_virtiofsd(pid_file, socket_path)
        if File.exist?(pid_file)
          pid = File.read(pid_file).strip.to_i
          begin
            Process.kill("TERM", pid)
            5.times do
              begin
                Process.kill(0, pid)
                sleep 0.5
              rescue Errno::ESRCH
                break
              end
            end
            Process.kill("KILL", pid) rescue nil
          rescue Errno::ESRCH
            # Already dead
          end
          File.delete(pid_file) rescue nil
        end
        File.delete(socket_path) if File.exist?(socket_path)
      end
    end
  end
end
