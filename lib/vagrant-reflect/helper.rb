require 'vagrant/util/platform'

require_relative 'patched/subprocess'

module VagrantReflect
  # This is a helper that abstracts out the functionality of rsyncing
  # folders so that it can be called from anywhere.
  class SyncHelper
    # This converts an rsync exclude pattern to a regular expression
    # we can send to Listen.
    def self.exclude_to_regexp(path, exclude)
      start_anchor = false

      if exclude.start_with?('/')
        start_anchor = true
        exclude      = exclude[1..-1]
      end

      path   = "#{path}/" unless path.end_with?('/')
      regexp = "^#{Regexp.escape(path)}"
      regexp += '.*' unless start_anchor

      # This is REALLY ghetto, but its a start. We can improve and
      # keep unit tests passing in the future.
      exclude = exclude.gsub('**', '|||GLOBAL|||')
      exclude = exclude.gsub('*', '|||PATH|||')
      exclude = exclude.gsub('|||PATH|||', '[^/]*')
      exclude = exclude.gsub('|||GLOBAL|||', '.*')
      regexp += exclude

      Regexp.new(regexp)
    end

    def self.sync_single(machine, ssh_info, opts, &block)
      # Folder info
      guestpath = opts[:guestpath]
      hostpath  = opts[:hostpath]
      hostpath  = File.expand_path(hostpath, machine.env.root_path)
      hostpath  = Vagrant::Util::Platform.fs_real_path(hostpath).to_s

      if Vagrant::Util::Platform.windows?
        # rsync for Windows expects cygwin style paths, always.
        hostpath = Vagrant::Util::Platform.cygwin_path(hostpath)
      end

      # Make sure the host path ends with a "/" to avoid creating
      # a nested directory...
      hostpath += '/' unless hostpath.end_with?('/')

      # Folder options
      opts[:owner] ||= ssh_info[:username]
      opts[:group] ||= ssh_info[:username]

      # Connection information
      username = ssh_info[:username]
      host     = ssh_info[:host]
      proxy_command = ''
      if ssh_info[:proxy_command]
        proxy_command = "-o ProxyCommand='#{ssh_info[:proxy_command]}' "
      end

      rsh = [
        "ssh -p #{ssh_info[:port]} " +
          proxy_command +
          '-o StrictHostKeyChecking=no '\
          '-o IdentitiesOnly=true '\
          '-o UserKnownHostsFile=/dev/null',
        ssh_info[:private_key_path].map { |p| "-i '#{p}'" }
      ].flatten.join(' ')

      # Exclude some files by default, and any that might be configured
      # by the user.
      excludes = ['.vagrant/']
      excludes += Array(opts[:exclude]).map(&:to_s) if opts[:exclude]
      excludes.uniq!

      # Get the command-line arguments
      args = nil
      args = Array(opts[:args]).dup if opts[:args]
      args ||= ['--verbose', '--archive', '--delete', '-z', '--copy-links']

      # On Windows, we have to set a default chmod flag to avoid permission
      # issues
      if Vagrant::Util::Platform.windows?
        unless args.any? { |arg| arg.start_with?('--chmod=') }
          # Ensures that all non-masked bits get enabled
          args << '--chmod=ugo=rwX'

          # Remove the -p option if --archive is enabled (--archive equals
          # -rlptgoD) otherwise new files will not have the destination-default
          # permissions
          args << '--no-perms' if
            args.include?('--archive') || args.include?('-a')
        end
      end

      # Disable rsync's owner/group preservation (implied by --archive) unless
      # specifically requested, since we adjust owner/group to match shared
      # folder setting ourselves.
      args << '--no-owner' unless
        args.include?('--owner') || args.include?('-o')
      args << '--no-group' unless
        args.include?('--group') || args.include?('-g')

      # Tell local rsync how to invoke remote rsync with sudo
      if machine.guest.capability?(:rsync_command)
        args << '--rsync-path' << machine.guest.capability(:rsync_command)
      end

      args << '--files-from=-' if opts[:from_stdin] && block_given?

      # Build up the actual command to execute
      command = [
        'rsync',
        args,
        '-e', rsh,
        excludes.map { |e| ['--exclude', e] },
        hostpath,
        "#{username}@#{host}:#{guestpath}"
      ].flatten

      # The working directory should be the root path
      command_opts = {}
      command_opts[:workdir] = machine.env.root_path.to_s
      command_opts[:notify] = [:stdin] if opts[:from_stdin] && block_given?

      if opts[:from_stdin] && block_given?
        machine.ui.info(
          I18n.t(
            'vagrant.plugins.vagrant-reflect.rsync_folder_changes',
            guestpath: guestpath,
            hostpath: hostpath))
      else
        machine.ui.info(
          I18n.t(
            'vagrant.plugins.vagrant-reflect.rsync_folder',
            guestpath: guestpath,
            hostpath: hostpath))
      end
      if excludes.length > 1
        machine.ui.info(
          I18n.t(
            'vagrant.plugins.vagrant-reflect.rsync_folder_excludes',
            excludes: excludes.inspect))
      end

      # If we have tasks to do before rsyncing, do those.
      if machine.guest.capability?(:rsync_pre)
        machine.guest.capability(:rsync_pre, opts)
      end

      r = Vagrant::Util::SubprocessPatched.execute(*(command + [command_opts]), &block)
      if r.exit_code != 0
        raise Vagrant::Errors::RSyncError,
              command: command.join(' '),
              guestpath: guestpath,
              hostpath: hostpath,
              stderr: r.stderr
      end

      # If we have tasks to do after rsyncing, do those.
      if machine.guest.capability?(:rsync_post)
        machine.guest.capability(:rsync_post, opts)
      end
    end
  end
end