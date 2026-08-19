# frozen_string_literal: true

require 'fileutils'
require 'rbconfig'
require 'tmpdir'

require_relative 'stub_gh'

module Fixtures
  # Hands CliTestCase's serving-stub seam a program to install as `gh`.
  #
  # The seam takes a path and copies it onto PATH, knowing nothing about
  # what language the program is written in, which is what this module
  # exists to keep true. The sweep runs gh with the swept repository as
  # the child's working directory, and a `#!/usr/bin/env ruby` line
  # resolved from a throwaway directory can find a version-manager shim
  # with no version to resolve: it prints its list of installed versions
  # and never runs the program at all. The sweep would read that as an
  # empty answer rather than as a failure, and grade every branch as
  # having no pull request.
  #
  # So what gets installed is a /bin/sh wrapper naming this run's own
  # interpreter and the stub by absolute path. Nothing about it depends
  # on where it is run from, and the stub itself stays an ordinary Ruby
  # file that can be run and read on its own.
  module ForgeStub
    STUB = File.expand_path('stub_gh.rb', __dir__)

    # What the stub answers for when no --repo is passed, which is the
    # ordinary case: gh resolves the repository from its working
    # directory and the sweep leaves that to it.
    CWD = StubGh::CWD_KEY

    module_function

    # Written once per process and reused: every test installs the same
    # wrapper, and the data it serves comes from the environment rather
    # than from the program.
    def program
      @program ||= write_wrapper
    end

    # at_exit rather than the block form every other fixture uses: the
    # wrapper has to outlive the call that writes it, since it is on
    # PATH for the length of the process.
    def write_wrapper
      dir = Dir.mktmpdir('forge-stub')
      at_exit { FileUtils.remove_entry(dir) if File.directory?(dir) }
      path = File.join(dir, 'gh')
      File.write(path, <<~SCRIPT)
        #!/bin/sh
        exec "#{RbConfig.ruby}" "#{STUB}" "$@"
      SCRIPT
      File.chmod(0o755, path)
      path
    end
  end
end
