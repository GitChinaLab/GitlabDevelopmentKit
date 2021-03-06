# frozen_string_literal: true

require 'erb'
require 'fileutils'
require_relative '../gdk/config'

module Runit
  class Config
    attr_reader :gdk_root

    Service = Struct.new(:name, :command)

    TERM_SIGNAL = {
      'webpack' => 'KILL'
    }.freeze

    def initialize(gdk_root)
      @gdk_root = gdk_root
    end

    def log_dir
      File.join(gdk_root, 'log')
    end

    def services_dir
      File.join(gdk_root, 'services')
    end

    def sv_dir
      File.join(gdk_root, 'sv')
    end

    def run_env
      @run_env ||= generate_run_env
    end

    def render(services: services_from_procfile)
      FileUtils.mkdir_p(services_dir)
      FileUtils.mkdir_p(log_dir)

      max_service_length = services.map { |svc| svc.name.size }.max

      services.each_with_index do |service, i|
        create_runit_service(service)
        create_runit_control_t(service)
        create_runit_log_service(service, max_service_length, i)
        enable_runit_service(service)
      end

      FileUtils.rm(stale_service_links(services))
    end

    def stale_service_links(services)
      service_names = services.map(&:name)
      dir_matcher = %w[. ..]

      stale_entries = Dir.entries(services_dir).reject do |svc|
        service_names.include?(svc) || dir_matcher.include?(svc)
      end

      stale_entries.map do |entry|
        path = File.join(services_dir, entry)
        next unless File.symlink?(path)

        path
      end.compact
    end

    private

    def procfile_path
      @procfile_path ||= gdk_root.join('Procfile')
    end

    def generate_run_env
      run_env = <<~RUN_ENV
        export host=#{GDK.config.hostname}
        export port=#{GDK.config.port}
        export relative_url_root=#{GDK.config.relative_url_root}
        export cache_classes=#{GDK.config.gitlab.cache_classes}
        export bundle_gemfile=#{GDK.config.gitlab.rails.bundle_gemfile}
      RUN_ENV

      if GDK.config.tracer.jaeger?
        run_env += <<~RUN_ENV
          export GITLAB_TRACING='#{GDK.config.tracer.jaeger.__tracer_url}'
          export GITLAB_TRACING_URL='#{GDK.config.tracer.jaeger.__search_url}'
        RUN_ENV
      end

      run_env
    end

    def services_from_procfile
      abort 'fatal: need Procfile to continue, make it with `make Procfile`?' unless procfile_path.exist?

      procfile_path.readlines.map do |line|
        line.chomp!
        next if line.start_with?('#')

        name, command = line.split(': ', 2)
        next unless name && command

        delete_exec_prefix!(name, command)

        Service.new(name, command)
      end.compact
    end

    def delete_exec_prefix!(service, command)
      exec_prefix = 'exec '
      abort "fatal: Procfile command for service #{service} does not start with 'exec'" unless command.start_with?(exec_prefix)

      command.delete_prefix!(exec_prefix)
    end

    def create_runit_service(service)
      run_template = <<~TEMPLATE
        #!/bin/sh
        set -e

        exec 2>&1
        cd <%=  gdk_root %>

        <%= run_env %>

        test -f env.runit && . ./env.runit

        # Use chpst -P to run the command in its own process group
        exec chpst -P <%= service.command %>
      TEMPLATE

      run_path = File.join(dir(service), 'run')
      write_file(run_path, ERB.new(run_template).result(binding), 0o755)

      # Create a 'down' file so that runsvdir won't boot this service until
      # you request it with `sv start`.
      write_file(File.join(dir(service), 'down'), '', 0o644)
    end

    def create_runit_control_t(service)
      term_signal = TERM_SIGNAL.fetch(service.name, 'TERM')

      control_t_template = <<~'TEMPLATE'
        #!/usr/bin/env ruby

        def kill(signal, pid)
          puts "runit control/t: sending #{signal} to #{pid}"
          Process.kill(signal, pid)
        rescue SystemCallError
          nil
        end

        def pid
          @pid ||= begin
            p = File.read('<%= File.join(dir(service), 'supervise/pid') %>')
            return if p.empty?

            Integer(p)
          end
        end

        exit(0) unless pid

        # Kill PID group with <%= term_signal %>
        kill('<%= term_signal %>', -pid)

        # Kill PID with <%= term_signal %>
        kill('<%= term_signal %>', pid)
      TEMPLATE
      control_t_path = File.join(dir(service), 'control/t')
      write_file(control_t_path, ERB.new(control_t_template).result(binding), 0o755)
    end

    def create_runit_log_service(service, max_service_length, index)
      service_log_dir = File.join(log_dir, service.name)
      FileUtils.mkdir_p(service_log_dir)

      log_run_template = <<~TEMPLATE
        #!/bin/sh
        set -e

        # svlogd is a long-running daemon so it should run from /
        cd /

        exec svlogd -tt <%= service_log_dir %>
      TEMPLATE

      log_run_path = File.join(dir(service), 'log/run')
      write_file(log_run_path, ERB.new(log_run_template).result(binding), 0o755)

      log_prefix = GDK::Output.ansi(GDK::Output.color(index))
      log_label = format("%-#{max_service_length}s : ", service.name)
      reset_color = GDK::Output.reset_color

      # See http://smarden.org/runit/svlogd.8.html#sect6 for documentation of the svlogd config file
      log_config_template = <<~TEMPLATE
        # zip old log files
        !gzip
        # custom log prefix for <%= service.name %>
        p<%= log_prefix + log_label + reset_color %>
        # keep at most 1 old log file
        n1
      TEMPLATE

      log_config_path = File.join(service_log_dir, 'config')
      write_file(log_config_path, ERB.new(log_config_template).result(binding), 0o644)
    end

    def enable_runit_service(service)
      # If the user removes this symlink, runit will stop managing this service.
      FileUtils.ln_sf(dir(service), File.join(services_dir, service.name))
    end

    def dir(service)
      File.join(sv_dir, service.name)
    end

    def write_file(path, content, perm)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, 'w') { |f| f.write(content) }
      File.chmod(perm, path)
    end
  end
end
