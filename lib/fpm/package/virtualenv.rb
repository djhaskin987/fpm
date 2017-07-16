require "fpm/namespace"
require "fpm/package"
require "fpm/util"

# Support for python virtualenv packages.
#
# This supports input, but not output.
#
class FPM::Package::Virtualenv < FPM::Package
  # Flags '--foo' will be accessable  as attributes[:virtualenv_foo]


  option "--pypi", "PYPI_URL",
  "PyPi Server uri for retrieving packages.",
  :default => "https://pypi.python.org/simple"
  option "--package-name-prefix", "PREFIX", "Name to prefix the package " \
  "name with.", :default => "virtualenv"

  option "--install-location", "DIRECTORY", "DEPRECATED: Use --prefix instead." \
    "  Location to which to install the virtualenv by default.",
    :default => "/usr/share/python" do |path|
    logger.warn("Using deprecated flag: --install-location. Please use " \
                  "--prefix instead.")
    File.expand_path(path)
  end

  option "--fix-name", :flag, "Should the target package name be prefixed?",
  :default => true
  option "--other-files-dir", "DIRECTORY", "Optionally, the contents of the " \
  "specified directory may be added to the package. This is useful if the " \
  "virtualenv needs configuration files, etc.", :default => nil
  option "--pypi-extra-url", "PYPI_EXTRA_URL",
    "PyPi extra-index-url for pointing to your priviate PyPi",
    :multivalued => true, :attribute_name => :virtualenv_pypi_extra_index_urls,
    :default => nil

  option "--setup-install", :flag, "After building virtualenv run setup.py install "\
  "useful when building a virtualenv for packages and including their requirements from "
  "requirements.txt"

  option "--system-site-packages", :flag, "Give the virtual environment access to the "\
  "global site-packages"

  option "--find-links", "PIP_FIND_LINKS", "If a url or path to an html file, then parse for "\
    "links to archives. If a local path or file:// url that's a directory, then look "\
    "for archives in the directory listing.",
    :multivalued => true, :attribute_name => :virtualenv_find_links_urls,
    :default => nil

  private

  # Input a package.
  #
  #     `package` can look like `psutil==2.2.1` or `psutil`.
  def input(package)
    installdir = attributes[:virtualenv_install_location]
    m = /^([^=]+)==([^=]+)$/.match(package)
    package_version = nil

    is_requirements_file = (File.basename(package) == "requirements.txt")
    is_directory = FileTest.directory?(package)

    if is_requirements_file
      if !File.file?(package)
        raise FPM::InvalidPackageConfiguration, "Path looks like a requirements.txt, but it doesn't exist: #{package}"
      end

      package = File.join(::Dir.pwd, package) if File.dirname(package) == "."
      package_name = File.basename(File.dirname(package))
      if !self.name
        logger.info("No name given. Using the directory's name", :name => package_name)
      end
      package_version = nil
    elsif is_directory
      if !FileTest.exists?(File.join(package, "bin", "pip"))
        raise FPM::InvalidPackageConfiguation, "Path `#{package}` is a directory, but not a virtualenv."
      end
      package = File.absolute_path(package)
      package_name = File.basename(package)
      if !self.name
        logger.info("No name given. Using the directory's name", :name => package_name)
      end
      package_version = nil
    elsif m
      package_name = m[1]
      package_version = m[2]
    else
      package_name = package
      package_version = nil
    end

    self.name ||= package_name
    self.version ||= package_version

    if self.attributes[:virtualenv_fix_name?]
      self.name = [self.attributes[:virtualenv_package_name_prefix],
                   self.name].join("-")
    end

    # prefix wins over previous virtual_install_location behaviour
    virtualenv_folder =
      if self.attributes[:prefix]
        self.attributes[:prefix]
      else
        File.join(installdir,
                  package_name)
      end

    virtualenv_build_folder = build_path(virtualenv_folder)
    ::FileUtils.mkdir_p(virtualenv_build_folder)

    if is_directory
      sync_directories(package, virtualenv_build_folder)
      safesystem("virtualenv-tools", "--update-path", virtualenv_build_folder)
    else
      virtualenv_options = ["virtualenv"]
      if self.attributes[:virtualenv_system_site_packages?]
          logger.info("Creating virtualenv with --system-site-packages")
          virtualenv_options << "--system-site-packages"
      end
      virtualenv_options << virtualenv_build_folder
      safesystem(*virtualenv_options)
    end

    pip_exe = File.join(virtualenv_build_folder, "bin", "pip")
    python_exe = File.join(virtualenv_build_folder, "bin", "python")

    safesystem(python_exe, pip_exe, "install", "-U", "-i",
               attributes[:virtualenv_pypi],
               "pip", "distribute")
    safesystem(python_exe, pip_exe, "uninstall", "-y", "distribute")

    extra_index_url_args = []
    if attributes[:virtualenv_pypi_extra_index_urls]
      attributes[:virtualenv_pypi_extra_index_urls].each do |extra_url|
        extra_index_url_args << "--extra-index-url" << extra_url
      end
    end

    find_links_url_args = []
    if attributes[:virtualenv_find_links_urls]
      attributes[:virtualenv_find_links_urls].each do |links_url|
        find_links_url_args << "--find-links" << links_url
      end
    end

    target_args = []
    if is_requirements_file
      target_args << "-r" << package
    elsif !is_directory
      target_args << package
    end

    if !target_args.empty?
      pip_args = [python_exe, pip_exe, "install", "-i", attributes[:virtualenv_pypi]] << extra_index_url_args << find_links_url_args << target_args
      safesystem(*pip_args.flatten)
    end

    if attributes[:virtualenv_setup_install?]
      logger.info("Running PACKAGE setup.py")
      setup_args = [python_exe, "setup.py", "install"]
      safesystem(*setup_args.flatten)
    end

    # Final try at setting the package version
    if package_version.nil?
      frozen = safesystemout(python_exe, pip_exe, "freeze")
      frozen_version = frozen[/#{package_name}==[^=]+$/]
      package_version = frozen_version && frozen_version.split("==")[1].chomp!
      self.version ||= package_version
    end

    ::Dir[build_path + "/**/*"].each do |f|
      if ! File.readable? f
        File.lchmod(File.stat(f).mode | 444)
      end
    end

    ::Dir.chdir(virtualenv_build_folder) do
      safesystem("virtualenv-tools", "--update-path", virtualenv_folder)
    end

    if !attributes[:virtualenv_other_files_dir].nil?
      sync_directories(attributes[:virtualenv_other_files_dir], build_path)
    end

    remove_python_compiled_files virtualenv_build_folder

    # Use dir to set stuff up properly, mainly so I don't have to reimplement
    # the chdir/prefix stuff special for tar.
    dir = convert(FPM::Package::Dir)
    # don't double prefix the files
    dir.attributes[:prefix] = nil
    if attributes[:chdir]
      dir.attributes[:chdir] = File.join(build_path, attributes[:chdir])
    else
      dir.attributes[:chdir] = build_path
    end

    cleanup_staging
    # Tell 'dir' to input "." and chdir/prefix will help it figure out the
    # rest.
    dir.input(".")
    @staging_path = dir.staging_path
    dir.cleanup_build

  end # def input

  def sync_directories(from,to)
    # Copy all files in `from` into the directory `to`
    ::FileUtils.mkdir_p(to)
    Find.find(from) do |path|
      src = path.gsub(/^#{from}/, '')
      dst = File.join(to, src)
      copy_entry(path, dst, preserve=true, remove_destination=true)
      copy_metadata(path, dst)
    end
  end

  # Delete python precompiled files found in a given folder.
  def remove_python_compiled_files path
    logger.debug("Now removing python object and compiled files from the virtualenv")
    Find.find(path) do |path|
      if path.end_with? '.pyc' or path.end_with? '.pyo'
        FileUtils.rm path
      end
    end
  end
  public(:input)
end # class FPM::Package::Virtualenv
