!> # Dependency management
!>
!> ## Fetching dependencies and creating a dependency tree
!>
!> Dependencies on the top-level can be specified from:
!>
!> - `package%dependencies`
!> - `package%dev_dependencies`
!> - `package%executable(:)%dependencies`
!> - `package%test(:)%dependencies`
!>
!> Each dependency is fetched in some way and provides a path to its package
!> manifest.
!> The `package%dependencies` of the dependencies are resolved recursively.
!>
!> To initialize the dependency tree all dependencies are recursively fetched
!> and stored in a flat data structure to avoid retrieving a package twice.
!> The data structure used to store this information should describe the current
!> status of the dependency tree. Important information are:
!>
!> - name of the package
!> - version of the package
!> - path to the package root
!>
!> Additionally, for version controlled dependencies the following should be
!> stored along with the package:
!>
!> - the upstream url
!> - the current checked out revision
!>
!> Fetching a remote (version controlled) dependency turns it for our purpose
!> into a local path dependency which is handled by the same means.
!>
!> ## Updating dependencies
!>
!> For a given dependency tree all top-level dependencies can be updated.
!> We have two cases to consider, a remote dependency and a local dependency,
!> again, remote dependencies turn into local dependencies by fetching.
!> Therefore we will update remote dependencies by simply refetching them.
!>
!> For remote dependencies we have to refetch if the revision in the manifest
!> changes or the upstream HEAD has changed (for branches _and_ tags).
!>
!> @Note For our purpose a tag is just a fancy branch name. Tags can be delete and
!>       modified afterwards, therefore they do not differ too much from branches
!>       from our perspective.
!>
!> For the latter case we only know if we actually fetch from the upstream URL.
!>
!> In case of local (and fetched remote) dependencies we have to read the package
!> manifest and compare its dependencies against our dependency tree, any change
!> requires updating the respective dependencies as well.
!>
!> ## Handling dependency compatibilties
!>
!> Currenly ignored. First come, first serve.
module fpm_dependency
  use, intrinsic :: iso_fortran_env, only: output_unit
  use fpm_environment, only: get_os_type, OS_WINDOWS, os_is_unix
  use fpm_error, only: error_t, fatal_error
  use fpm_filesystem, only: exists, join_path, mkdir, canon_path, windows_path, list_files, is_dir, basename, &
                            os_delete_dir, get_temp_filename, parent_dir
  use fpm_git, only: git_target_revision, git_target_default, git_revision, serializable_t
  use fpm_manifest, only: package_config_t, dependency_config_t, get_package_data, get_package_dependencies
  use fpm_manifest_dependency, only: manifest_has_changed, dependency_destroy
  use fpm_manifest_preprocess, only: operator(==)
  use fpm_strings, only: string_t, operator(.in.), operator(==), str
  use tomlf, only: toml_table, toml_key, toml_error, toml_load, toml_stat, toml_array, len, add_array
  use fpm_toml, only: toml_serialize, get_value, set_value, add_table, set_string, get_list, set_list
  use fpm_versioning, only: version_t, new_version
  use fpm_settings, only: fpm_global_settings, get_global_settings, official_registry_base_url
  use fpm_downloader, only: downloader_t
  use jonquil, only: json_object
  implicit none
  private

  public :: dependency_tree_t, new_dependency_tree, dependency_node_t, new_dependency_node, resize, &
            & check_and_read_pkg_data, destroy_dependency_node

  !> Overloaded reallocation interface
  interface resize
    module procedure :: resize_dependency_node
  end interface resize

  !> Dependency node in the projects dependency tree
  type, extends(dependency_config_t) :: dependency_node_t
    !> Actual version of this dependency
    type(version_t), allocatable  :: version
    !> Installation prefix of this dependencies
    character(len=:), allocatable :: proj_dir
    !> Checked out revision of the version control system
    character(len=:), allocatable :: revision
    !> Dependency is handled
    logical :: done = .false.
    !> Dependency should be updated
    logical :: update = .false.
    !> Dependency was loaded from a cache
    logical :: cached = .false.
    !> Package dependencies of this node 
    type(string_t), allocatable :: package_dep(:)    
  contains

    !> Update dependency from project manifest.
    procedure :: register    

    !> Get dependency from the registry.
    procedure :: get_from_registry
    procedure, private :: get_from_local_registry
    !> Print information on this instance
    procedure :: info

    !> Serialization interface
    procedure :: serializable_is_same => dependency_node_is_same
    procedure :: dump_to_toml         => node_dump_to_toml
    procedure :: load_from_toml       => node_load_from_toml

  end type dependency_node_t

  !> Respresentation of a projects dependencies
  !>
  !> The dependencies are stored in a simple array for now, this can be replaced
  !> with a binary-search tree or a hash table in the future.
  type, extends(serializable_t) :: dependency_tree_t
    !> Unit for IO
    integer :: unit = output_unit
    !> Verbosity of printout
    integer :: verbosity = 1
    !> Installation prefix for dependencies
    character(len=:), allocatable :: dep_dir
    !> Number of currently registered dependencies
    integer :: ndep = 0
    !> Flattend list of all dependencies
    type(dependency_node_t), allocatable :: dep(:)
    !> Cache file
    character(len=:), allocatable :: cache
    !> Custom path to the global config file
    character(len=:), allocatable :: path_to_config

  contains

    !> Overload procedure to add new dependencies to the tree
    generic :: add => add_project, add_project_dependencies, add_dependencies, &
      add_dependency, add_dependency_node
    !> Main entry point to add a project
    procedure, private :: add_project
    !> Add a project and its dependencies to the dependency tree
    procedure, private :: add_project_dependencies
    !> Add a list of dependencies to the dependency tree
    procedure, private :: add_dependencies
    !> Add a single dependency to the dependency tree
    procedure, private :: add_dependency
    !> Add a single dependency node to the dependency tree
    procedure, private :: add_dependency_node
    !> Resolve dependencies
    generic :: resolve => resolve_dependencies, resolve_dependency
    !> Resolve dependencies
    procedure, private :: resolve_dependencies
    !> Resolve dependency
    procedure, private :: resolve_dependency
    !> True if entity can be found
    generic :: has => has_dependency
    !> True if dependency is part of the tree
    procedure, private :: has_dependency
    !> Find a dependency in the tree
    generic :: find => find_name
    !> Find a dependency by its name
    procedure, private :: find_name
    !> Establish local link order for a node's package dependencies
    procedure :: local_link_order
    !> Depedendncy resolution finished
    procedure :: finished
    !> Reading of dependency tree
    generic :: load_cache => load_cache_from_file, load_cache_from_unit, load_cache_from_toml
    !> Read dependency tree from file
    procedure, private :: load_cache_from_file
    !> Read dependency tree from formatted unit
    procedure, private :: load_cache_from_unit
    !> Read dependency tree from TOML data structure
    procedure, private :: load_cache_from_toml
    !> Writing of dependency tree
    generic :: dump_cache => dump_cache_to_file, dump_cache_to_unit, dump_cache_to_toml
    !> Write dependency tree to file
    procedure, private :: dump_cache_to_file
    !> Write dependency tree to formatted unit
    procedure, private :: dump_cache_to_unit
    !> Write dependency tree to TOML data structure
    procedure, private :: dump_cache_to_toml
    !> Update dependency tree
    generic :: update => update_dependency, update_tree
    !> Update a list of dependencies
    procedure, private :: update_dependency
    !> Update all dependencies in the tree
    procedure, private :: update_tree

    !> Serialization interface
    procedure :: serializable_is_same => dependency_tree_is_same
    procedure :: dump_to_toml         => tree_dump_to_toml
    procedure :: load_from_toml       => tree_load_from_toml

  end type dependency_tree_t

  !> Common output format for writing to the command line
  character(len=*), parameter :: out_fmt = '("#", *(1x, g0))'

contains

  !> Create a new dependency tree
  subroutine new_dependency_tree(self, verbosity, cache, path_to_config)
    !> Instance of the dependency tree
    type(dependency_tree_t), intent(out) :: self
    !> Verbosity of printout
    integer, intent(in), optional :: verbosity
    !> Name of the cache file
    character(len=*), intent(in), optional :: cache
    !> Path to the global config file.
    character(len=*), intent(in), optional :: path_to_config

    call resize(self%dep)
    self%dep_dir = join_path("build", "dependencies")

    if (present(verbosity)) self%verbosity = verbosity

    if (present(cache)) self%cache = cache

    if (present(path_to_config)) self%path_to_config = path_to_config

  end subroutine new_dependency_tree

  !> Create a new dependency node from a configuration
  subroutine new_dependency_node(self, dependency, version, proj_dir, update)
    !> Instance of the dependency node
    type(dependency_node_t), intent(out) :: self
    !> Dependency configuration data
    type(dependency_config_t), intent(in) :: dependency
    !> Version of the dependency
    type(version_t), intent(in), optional :: version
    !> Installation prefix of the dependency
    character(len=*), intent(in), optional :: proj_dir
    !> Dependency should be updated
    logical, intent(in), optional :: update

    self%dependency_config_t = dependency

    if (present(version)) then
      self%version = version
    end if

    if (present(proj_dir)) then
      self%proj_dir = proj_dir
    end if

    if (present(update)) then
      self%update = update
    end if

  end subroutine new_dependency_node

  !> Write information on instance
  subroutine info(self, unit, verbosity)

    !> Instance of the dependency configuration
    class(dependency_node_t), intent(in) :: self

    !> Unit for IO
    integer, intent(in) :: unit

    !> Verbosity of the printout
    integer, intent(in), optional :: verbosity

    integer :: pr, i
    character(len=*), parameter :: fmt = '("#", 1x, a, t30, a)'

    if (present(verbosity)) then
      pr = verbosity
    else
      pr = 1
    end if

    !> Call base object info
    call self%dependency_config_t%info(unit, pr)

    if (allocated(self%version)) then
      write (unit, fmt) "- version", self%version%s()
    end if

    if (allocated(self%proj_dir)) then
      write (unit, fmt) "- dir", self%proj_dir
    end if

    if (allocated(self%revision)) then
      write (unit, fmt) "- revision", self%revision
    end if

    write (unit, fmt) "- done", merge('YES', 'NO ', self%done)
    write (unit, fmt) "- update", merge('YES', 'NO ', self%update)
    
    if (allocated(self%package_dep)) then
        write(unit, fmt) " - package_dep "
        do i = 1, size(self%package_dep)
           write(unit, fmt) "   - " // self%package_dep(i)%s
        end do            
    end if
    
  end subroutine info

  !> Add project dependencies, each depth level after each other.
  !>
  !> We implement this algorithm in an interative rather than a recursive fashion
  !> as a choice of design.
  subroutine add_project(self, package, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> Project configuration to add
    type(package_config_t), intent(in) :: package
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    type(dependency_config_t) :: dependency
    type(dependency_tree_t) :: cached
    character(len=*), parameter :: root = '.'
    integer :: id

    if (.not. exists(self%dep_dir)) then
      call mkdir(self%dep_dir)
    end if

    ! Create this project as the first dependency node (depth 0)
    dependency%name = package%name
    dependency%path = root
    call self%add(dependency, error)
    if (allocated(error)) return

    ! Resolve the root project
    call self%resolve(root, error)
    if (allocated(error)) return
    
    ! Add the root project dependencies (depth 1)
    call self%add(package, root, .true., error)
    if (allocated(error)) return

    ! After resolving all dependencies, check if we have cached ones to avoid updates
    if (allocated(self%cache)) then
      call new_dependency_tree(cached, verbosity=self%verbosity,cache=self%cache)
      call cached%load_cache(self%cache, error)
      if (allocated(error)) return

      ! Skip root node
      do id = 2, cached%ndep
        cached%dep(id)%cached = .true.
        call self%add(cached%dep(id), error)
        if (allocated(error)) return
      end do
    end if

    ! Now decent into the dependency tree, level for level
    do while (.not. self%finished())
      call self%resolve(root, error)
      if (allocated(error)) exit
    end do
    if (allocated(error)) return
        
    ! Resolve internal dependency graph and remove temporary package storage
    call resolve_dependency_graph(self, package, error)
    if (allocated(error)) return

    if (allocated(self%cache)) then
      call self%dump_cache(self%cache, error)
      if (allocated(error)) return
    end if

  end subroutine add_project

  subroutine resolve_dependency_graph(self, main, error)
      !> Instance of the dependency tree
      class(dependency_tree_t), intent(inout) :: self
      !> Main project configuration 
      type(package_config_t), intent(in) :: main      
      !> Error handling
      type(error_t), allocatable, intent(out) :: error

      integer :: i,nit
      integer, parameter   :: MAXIT = 50
      logical, allocatable :: finished(:)
      type(string_t), allocatable :: old_package_dep(:)
      
      if (self%ndep<1) then 
          call fatal_error(error, "Trying to compute the dependency graph of an empty tree")
          return
      end if
      
      nit = 0
      allocate(finished(self%ndep),source=.false.)
      do while (.not.all(finished) .and. nit<MAXIT)
        
          nit = nit+1
      
          do i = 1, self%ndep
            
              ! Save old deps
              call move_alloc(from=self%dep(i)%package_dep,to=old_package_dep)
              
              call get_required_packages(self, i, error=error)
              if (allocated(error)) return
              
              finished(i) = all_alloc(self%dep(i)%package_dep, old_package_dep)
              
          end do  
      
      end do
      
      if (nit>=MAXIT) call fatal_error(error, "Infinite loop detected computing the dependency graph")
      
      contains
      
      pure logical function all_alloc(this,that)
          type(string_t), intent(in), allocatable :: this(:),that(:)
          all_alloc = .false.
          if (allocated(this).neqv.allocated(that)) return
          if (.not.allocated(this)) then 
              all_alloc = .true.
          else  
              if (size(this)/=size(that)) return
              if (.not.(this==that)) return
              all_alloc = .true.
          end if
      end function all_alloc

  end subroutine resolve_dependency_graph

  !> Add a project and its dependencies to the dependency tree
  recursive subroutine add_project_dependencies(self, package, root, main, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> Project configuration to add
    type(package_config_t), intent(in) :: package
    !> Current project root directory
    character(len=*), intent(in) :: root
    !> Is the main project
    logical, intent(in) :: main
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    integer :: ii

    if (allocated(package%dependency)) then
      call self%add(package%dependency, error)
      if (allocated(error)) return
    end if

    if (main) then
      if (allocated(package%dev_dependency)) then
        call self%add(package%dev_dependency, error)
        if (allocated(error)) return
      end if

      if (allocated(package%executable)) then
        do ii = 1, size(package%executable)
          if (allocated(package%executable(ii)%dependency)) then
            call self%add(package%executable(ii)%dependency, error)
            if (allocated(error)) exit
          end if
        end do
        if (allocated(error)) return
      end if

      if (allocated(package%example)) then
        do ii = 1, size(package%example)
          if (allocated(package%example(ii)%dependency)) then
            call self%add(package%example(ii)%dependency, error)
            if (allocated(error)) exit
          end if
        end do
        if (allocated(error)) return
      end if

      if (allocated(package%test)) then
        do ii = 1, size(package%test)
          if (allocated(package%test(ii)%dependency)) then
            call self%add(package%test(ii)%dependency, error)
            if (allocated(error)) exit
          end if
        end do
        if (allocated(error)) return
      end if
    end if

    !> Ensure allocation fits
    call resize(self%dep,self%ndep)

  end subroutine add_project_dependencies

  !> Add a list of dependencies to the dependency tree
  subroutine add_dependencies(self, dependency, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> Dependency configuration to add
    type(dependency_config_t), intent(in) :: dependency(:)
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    integer :: ii, ndep

    ndep = size(self%dep)
    if (ndep < size(dependency) + self%ndep) then
      call resize(self%dep, ndep + ndep/2 + size(dependency))
    end if

    do ii = 1, size(dependency)
      call self%add(dependency(ii), error)
      if (allocated(error)) exit
    end do
    if (allocated(error)) return

    !> Ensure allocation fits ndep
    call resize(self%dep,self%ndep)

  end subroutine add_dependencies

  !> Add a single dependency node to the dependency tree
  !> Dependency nodes contain additional information (version, git, revision)
  subroutine add_dependency_node(self, dependency, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> Dependency configuration to add
    type(dependency_node_t), intent(in) :: dependency
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    integer :: id

    if (self%has_dependency(dependency)) then
      ! A dependency with this same name is already in the dependency tree.
      ! Check if it needs to be updated
      id = self%find(dependency%name)

      ! If this dependency was in the cache, and we're now requesting a different version
      ! in the manifest, ensure it is marked for update. Otherwise, if we're just querying
      ! the same dependency from a lower branch of the dependency tree, the existing one from
      ! the manifest has priority
      if (dependency%cached) then
        if (dependency_has_changed(dependency, self%dep(id), self%verbosity, self%unit)) then
          if (self%verbosity > 0) write (self%unit, out_fmt) "Dependency change detected:", dependency%name
          self%dep(id)%update = .true.
        else
          ! Store the cached one
          self%dep(id) = dependency
          self%dep(id)%update = .false.
        end if
      end if
    else

      !> Safety: reallocate if necessary
      if (size(self%dep)==self%ndep) call resize(self%dep,self%ndep+1)

      ! New dependency: add from scratch
      self%ndep = self%ndep + 1
      self%dep(self%ndep) = dependency
      self%dep(self%ndep)%update = .false.
    end if

  end subroutine add_dependency_node

  !> Add a single dependency to the dependency tree
  subroutine add_dependency(self, dependency, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> Dependency configuration to add
    type(dependency_config_t), intent(in) :: dependency
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    type(dependency_node_t) :: node

    call new_dependency_node(node, dependency)
    call add_dependency_node(self, node, error)

  end subroutine add_dependency

  !> Update dependency tree
  subroutine update_dependency(self, name, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> Name of the dependency to update
    character(len=*), intent(in) :: name
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    integer :: id
    character(len=:), allocatable :: proj_dir, root

    id = self%find(name)
    root = "."

    if (id <= 0) then
      call fatal_error(error, "Cannot update dependency '"//name//"'")
      return
    end if

    associate (dep => self%dep(id))
      if (allocated(dep%git) .and. dep%update) then
        if (self%verbosity > 0) write (self%unit, out_fmt) "Update:", dep%name
        proj_dir = join_path(self%dep_dir, dep%name)
        call dep%git%checkout(proj_dir, error)
        if (allocated(error)) return

        ! Unset dependency and remove updatable attribute
        dep%done = .false.
        dep%update = .false.

        ! Now decent into the dependency tree, level for level
        do while (.not. self%finished())
          call self%resolve(root, error)
          if (allocated(error)) exit
        end do
        if (allocated(error)) return
      end if
    end associate

  end subroutine update_dependency

  !> Update whole dependency tree
  subroutine update_tree(self, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    integer :: i

    ! Update dependencies where needed
    do i = 1, self%ndep
      call self%update(self%dep(i)%name, error)
      if (allocated(error)) return
    end do

  end subroutine update_tree

  !> Resolve all dependencies in the tree
  subroutine resolve_dependencies(self, root, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> Current installation prefix
    character(len=*), intent(in) :: root
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    type(fpm_global_settings) :: global_settings
    character(:), allocatable :: parent_directory
    integer :: ii

    ! Register path to global config file if it was entered via the command line.
    if (allocated(self%path_to_config)) then
      if (len_trim(self%path_to_config) > 0) then
        parent_directory = parent_dir(self%path_to_config)

        if (len_trim(parent_directory) == 0) then
          global_settings%path_to_config_folder = "."
        else
          global_settings%path_to_config_folder = parent_directory
        end if

        global_settings%config_file_name = basename(self%path_to_config)
      end if
    end if

    call get_global_settings(global_settings, error)
    if (allocated(error)) return

    do ii = 1, self%ndep
      call self%resolve(self%dep(ii), global_settings, root, error)
      if (allocated(error)) exit
    end do

    if (allocated(error)) return

  end subroutine resolve_dependencies

  !> Resolve a single dependency node
  subroutine resolve_dependency(self, dependency, global_settings, root, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> Dependency configuration to add
    type(dependency_node_t), intent(inout) :: dependency
    !> Global configuration settings.
    type(fpm_global_settings), intent(in) :: global_settings
    !> Current installation prefix
    character(len=*), intent(in) :: root
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    type(package_config_t) :: package
    character(len=:), allocatable :: manifest, proj_dir, revision
    logical :: fetch

    if (dependency%done) return

    fetch = .false.
    if (allocated(dependency%proj_dir)) then
      proj_dir = dependency%proj_dir
    else if (allocated(dependency%path)) then
      proj_dir = join_path(root, dependency%path)
    else if (allocated(dependency%git)) then
      proj_dir = join_path(self%dep_dir, dependency%name)
      fetch = .not. exists(proj_dir)
      if (fetch) then
        call dependency%git%checkout(proj_dir, error)
        if (allocated(error)) return
      end if
    else
      call dependency%get_from_registry(proj_dir, global_settings, error)
      if (allocated(error)) return
    end if

    if (allocated(dependency%git)) then
      call git_revision(proj_dir, revision, error)
      if (allocated(error)) return
    end if

    manifest = join_path(proj_dir, "fpm.toml")
    call get_package_data(package, manifest, error)
    if (allocated(error)) return

    call dependency%register(package, proj_dir, fetch, revision, error)
    if (allocated(error)) return
    

    if (self%verbosity > 1) then
      write (self%unit, out_fmt) &
        "Dep:", dependency%name, "version", dependency%version%s(), &
        "at", dependency%proj_dir
    end if

    call self%add(package, proj_dir, .false., error)
    if (allocated(error)) return
    
  end subroutine resolve_dependency

  !> Get a dependency from the registry. Whether the dependency is fetched
  !> from a local, a custom remote or the official registry is determined
  !> by the global configuration settings.
  subroutine get_from_registry(self, target_dir, global_settings, error, downloader_)

    !> Instance of the dependency configuration.
    class(dependency_node_t), intent(in) :: self

    !> The target directory of the dependency.
    character(:), allocatable, intent(out) :: target_dir

    !> Global configuration settings.
    type(fpm_global_settings), intent(in) :: global_settings

    !> Error handling.
    type(error_t), allocatable, intent(out) :: error

    !> Downloader instance.
    class(downloader_t), optional, intent(in) :: downloader_

    character(:), allocatable :: cache_path, target_url, tmp_file
    type(version_t) :: version
    integer :: stat, unit
    type(json_object) :: json
    class(downloader_t), allocatable :: downloader

    if (present(downloader_)) then
      downloader = downloader_
    else
      allocate (downloader)
    end if

    ! Use local registry if it was specified in the global config file.
    if (allocated(global_settings%registry_settings%path)) then
      call self%get_from_local_registry(target_dir, global_settings%registry_settings%path, error); return
    end if

    ! Include namespace and package name in the cache path.
    cache_path = join_path(global_settings%registry_settings%cache_path, self%namespace, self%name)

    ! Check cache before downloading from the remote registry if a specific version was requested. When no specific
    ! version was requested, do network request first to check which is the newest version.
    if (allocated(self%requested_version)) then
      if (exists(join_path(cache_path, self%requested_version%s(), 'fpm.toml'))) then
        print *, "Using cached version of '", join_path(self%namespace, self%name, self%requested_version%s()), "'."
        target_dir = join_path(cache_path, self%requested_version%s()); return
      end if
    end if

    tmp_file = get_temp_filename()
    open (newunit=unit, file=tmp_file, action='readwrite', iostat=stat)
    if (stat /= 0) then
      call fatal_error(error, "Error creating temporary file for downloading package '"//self%name//"'."); return
    end if

    ! Include namespace and package name in the target url and download package data.
    target_url = global_settings%registry_settings%url//'/packages/'//self%namespace//'/'//self%name
    call downloader%get_pkg_data(target_url, self%requested_version, tmp_file, json, error)
    close (unit, status='delete')
    if (allocated(error)) return

    ! Verify package data and read relevant information.
    call check_and_read_pkg_data(json, self, target_url, version, error)
    if (allocated(error)) return

    ! Open new tmp file for downloading the actual package.
    open (newunit=unit, file=tmp_file, action='readwrite', iostat=stat)
    if (stat /= 0) then
      call fatal_error(error, "Error creating temporary file for downloading package '"//self%name//"'."); return
    end if

    ! Include version number in the cache path. If no cached version exists, download it.
    cache_path = join_path(cache_path, version%s())
    if (.not. exists(join_path(cache_path, 'fpm.toml'))) then
      if (is_dir(cache_path)) call os_delete_dir(os_is_unix(), cache_path)
      call mkdir(cache_path)

      call downloader%get_file(target_url, tmp_file, error)
      if (allocated(error)) then
        close (unit, status='delete'); return
      end if

      ! Unpack the downloaded package to the final location.
      call downloader%unpack(tmp_file, cache_path, error)
      close (unit, status='delete')
      if (allocated(error)) return
    end if

    target_dir = cache_path

  end subroutine get_from_registry

  subroutine check_and_read_pkg_data(json, node, download_url, version, error)
    type(json_object), intent(inout) :: json
    class(dependency_node_t), intent(in) :: node
    character(:), allocatable, intent(out) :: download_url
    type(version_t), intent(out) :: version
    type(error_t), allocatable, intent(out) :: error

    integer :: code, stat
    type(json_object), pointer :: p, q
    character(:), allocatable :: version_key, version_str, error_message, namespace, name

    namespace = ""
    name = "UNNAMED_NODE"
    if (allocated(node%namespace)) namespace = node%namespace
    if (allocated(node%name)) name = node%name

    if (.not. json%has_key('code')) then
      call fatal_error(error, "Failed to download '"//join_path(namespace, name)//"': No status code."); return
    end if

    call get_value(json, 'code', code, stat=stat)
    if (stat /= 0) then
      call fatal_error(error, "Failed to download '"//join_path(namespace, name)//"': "// &
      & "Failed to read status code."); return
    end if

    if (code /= 200) then
      if (.not. json%has_key('message')) then
        call fatal_error(error, "Failed to download '"//join_path(namespace, name)//"': No error message."); return
      end if

      call get_value(json, 'message', error_message, stat=stat)
      if (stat /= 0) then
        call fatal_error(error, "Failed to download '"//join_path(namespace, name)//"': "// &
        & "Failed to read error message."); return
      end if

      call fatal_error(error, "Failed to download '"//join_path(namespace, name)//"'. Status code: '"// &
      & str(code)//"'. Error message: '"//error_message//"'."); return
    end if

    if (.not. json%has_key('data')) then
      call fatal_error(error, "Failed to download '"//join_path(namespace, name)//"': No data."); return
    end if

    call get_value(json, 'data', p, stat=stat)
    if (stat /= 0) then
      call fatal_error(error, "Failed to read package data for '"//join_path(namespace, name)//"'."); return
    end if

    if (allocated(node%requested_version)) then
      version_key = 'version_data'
    else
      version_key = 'latest_version_data'
    end if

    if (.not. p%has_key(version_key)) then
      call fatal_error(error, "Failed to download '"//join_path(namespace, name)//"': No version data."); return
    end if

    call get_value(p, version_key, q, stat=stat)
    if (stat /= 0) then
      call fatal_error(error, "Failed to retrieve version data for '"//join_path(namespace, name)//"'."); return
    end if

    if (.not. q%has_key('download_url')) then
      call fatal_error(error, "Failed to download '"//join_path(namespace, name)//"': No download url."); return
    end if

    call get_value(q, 'download_url', download_url, stat=stat)
    if (stat /= 0) then
      call fatal_error(error, "Failed to read download url for '"//join_path(namespace, name)//"'."); return
    end if

    download_url = official_registry_base_url//download_url

    if (.not. q%has_key('version')) then
      call fatal_error(error, "Failed to download '"//join_path(namespace, name)//"': No version found."); return
    end if

    call get_value(q, 'version', version_str, stat=stat)
    if (stat /= 0) then
      call fatal_error(error, "Failed to read version data for '"//join_path(namespace, name)//"'."); return
    end if

    call new_version(version, version_str, error)
    if (allocated(error)) then
      call fatal_error(error, "'"//version_str//"' is not a valid version for '"// &
      & join_path(namespace, name)//"'."); return
    end if
  end subroutine

  !> Get the dependency from a local registry.
  subroutine get_from_local_registry(self, target_dir, registry_path, error)

    !> Instance of the dependency configuration.
    class(dependency_node_t), intent(in) :: self

    !> The target directory to download the dependency to.
    character(:), allocatable, intent(out) :: target_dir

    !> The path to the local registry.
    character(*), intent(in) :: registry_path

    !> Error handling.
    type(error_t), allocatable, intent(out) :: error

    character(:), allocatable :: path_to_name
    type(string_t), allocatable :: files(:)
    type(version_t), allocatable :: versions(:)
    type(version_t) :: version
    integer :: i

    path_to_name = join_path(registry_path, self%namespace, self%name)

    if (.not. exists(path_to_name)) then
      call fatal_error(error, "Dependency resolution of '"//self%name// &
      & "': Directory '"//path_to_name//"' doesn't exist."); return
    end if

    call list_files(path_to_name, files)
    if (size(files) == 0) then
      call fatal_error(error, "No versions of '"//self%name//"' found in '"//path_to_name//"'."); return
    end if

    ! Version requested, find it in the cache.
    if (allocated(self%requested_version)) then
      do i = 1, size(files)
        ! Identify directory that matches the version number.
        if (files(i)%s == join_path(path_to_name, self%requested_version%s()) .and. is_dir(files(i)%s)) then
          if (.not. exists(join_path(files(i)%s, 'fpm.toml'))) then
            call fatal_error(error, "'"//files(i)%s//"' is missing an 'fpm.toml' file."); return
          end if
          target_dir = files(i)%s; return
        end if
      end do
      call fatal_error(error, "Version '"//self%requested_version%s()//"' not found in '"//path_to_name//"'")
      return
    end if

    ! No specific version requested, therefore collect available versions.
    allocate (versions(0))
    do i = 1, size(files)
      if (is_dir(files(i)%s)) then
        call new_version(version, basename(files(i)%s), error)
        if (allocated(error)) return
        versions = [versions, version]
      end if
    end do

    if (size(versions) == 0) then
      call fatal_error(error, "No versions found in '"//path_to_name//"'"); return
    end if

    ! Find the latest version.
    version = versions(1)
    do i = 1, size(versions)
      if (versions(i) > version) version = versions(i)
    end do

    path_to_name = join_path(path_to_name, version%s())

    if (.not. exists(join_path(path_to_name, 'fpm.toml'))) then
      call fatal_error(error, "'"//path_to_name//"' is missing an 'fpm.toml' file."); return
    end if

    target_dir = path_to_name
  end subroutine get_from_local_registry

  !> True if dependency is part of the tree
  pure logical function has_dependency(self, dependency)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(in) :: self
    !> Dependency configuration to check
    class(dependency_node_t), intent(in) :: dependency

    has_dependency = self%find(dependency%name) /= 0

  end function has_dependency

  !> Find a dependency in the dependency tree
  pure function find_name(self, name) result(pos)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(in) :: self
    !> Dependency configuration to add
    character(len=*), intent(in) :: name
    !> Index of the dependency
    integer :: pos

    integer :: ii

    pos = 0
    do ii = 1, self%ndep
      if (name == self%dep(ii)%name) then
        pos = ii
        exit
      end if
    end do

  end function find_name

  !> Check if we are done with the dependency resolution
  pure function finished(self)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(in) :: self
    !> All dependencies are updated
    logical :: finished

    finished = all(self%dep(:self%ndep)%done)

  end function finished

  !> Update dependency from project manifest
  subroutine register(node, package, root, fetch, revision, error)
    !> Instance of the dependency node
    class(dependency_node_t), intent(inout) :: node
    !> Package configuration data
    type(package_config_t), intent(in) :: package
   
    !> Project has been fetched
    logical, intent(in) :: fetch
    !> Root directory of the project
    character(len=*), intent(in) :: root
    !> Git revision of the project
    character(len=*), intent(in), optional :: revision
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    logical :: update

    update = .false.
    if (node%name /= package%name) then
      call fatal_error(error, "Dependency name '"//package%name// &
        & "' found, but expected '"//node%name//"' instead")
        return
    end if

    node%version  = package%version
    node%proj_dir = root

    if (allocated(node%git) .and. present(revision)) then
      node%revision = revision
      if (.not. fetch) then
        ! Change in revision ID was checked already. Only update if ALL git information is missing
        update = .not. allocated(node%git%url)
      end if
    end if
  
    if (update) node%update = update
    node%done = .true.  
    
  end subroutine register

  !> Capture the list of "required" packages while the manifest is loaded. 
  !> This subroutine should be called during the "resolve" phase, i.e. when the whole 
  !> dependency tree has been built already
  subroutine get_required_packages(tree, node_ID, error)
      !> Instance of the dependency tree
      class(dependency_tree_t), intent(inout) :: tree     
      !> Instance of the dependency node
      integer, intent(in) :: node_ID
      !> Error handling
      type(error_t), allocatable, intent(out) :: error
      
      integer :: nreq,k,id
      type(dependency_config_t), allocatable :: dependency(:)
      type(package_config_t) :: manifest
      logical :: required(tree%ndep),main
      
      associate(node => tree%dep(node_ID))
        
      ! Is the main project
      main = node_ID==1  
      
      ! Get manifest
      call get_package_data(manifest, join_path(node%proj_dir,"fpm.toml"), error)
      if (allocated(error)) return
      
      call get_package_dependencies(manifest, main, dependency) 
      nreq = size(dependency)
    
      ! Translate names -> indices
      required = .false.

      do k = 1, nreq
        
          id = tree%find(dependency(k)%name)
          if (id<=0) then
             ! Shouldn't happen because tree already contains every dep
             call fatal_error(error, "Internal error: "//trim(node%name)// &
                  & " cannot find resolved dependency "//trim(dependency(k)%name)//" in tree")                  
             return             
          end if
          
          ! Recurse dependencies
          call recurse_deps(tree, id, required)
                    
      end do    
      
      ! Recursed list
      nreq = count(required)
      if (allocated(node%package_dep)) deallocate(node%package_dep)
      allocate(node%package_dep(nreq))  
      k = 0
      do id=1,tree%ndep
         if (.not.required(id)) cycle
         k = k+1
         node%package_dep(k) = string_t(tree%dep(id)%name)
      end do
      
      endassociate
      
      contains
                
          recursive subroutine recurse_deps(tree, id, required)
              class(dependency_tree_t), intent(in) :: tree
              integer, intent(in) :: id
              logical, intent(inout) :: required(:)

              integer :: j,dep_id
              
              if (required(id)) return
              
              required(id) = .true.
              if (allocated(tree%dep(id)%package_dep)) then
                  do j = 1, size(tree%dep(id)%package_dep)
                      dep_id = tree%find(tree%dep(id)%package_dep(j)%s)
                      call recurse_deps(tree, dep_id, required)
                  end do
              end if
          end subroutine recurse_deps         
      
  end subroutine get_required_packages  

  !> Build a correct topological link order for a given dependency node.
  !>
  !> This routine returns the list of dependencies required to build `root_id`,
  !> sorted such that each dependency appears *before* any node that depends on it.
  !> This is suitable for correct linker ordering: `-lA -lB` means B can use symbols from A.
  !>
  !> The returned list includes both the transitive dependencies and the node itself.
  !> Example: if node 3 requires [5, 7, 9, 2] and 9 also requires 2,
  !> then the result will ensure that 2 appears before 9, etc.
  subroutine local_link_order(tree, root_id, order, error)
    !> The full dependency graph
    class(dependency_tree_t), intent(in) :: tree
    !> Index of the node for which to compute link order (e.g., the target being linked)
    integer, intent(in) :: root_id
    !> Ordered list of dependency indices (subset of tree%dep(:)) in link-safe order
    integer, allocatable, intent(out) :: order(:)
    !> Optional fatal error if a cycle is detected (not expected)
    type(error_t), allocatable, intent(out) :: error

    !> Track which nodes have been visited
    logical, allocatable :: visited(:)
    !> Work stack holding post-order DFS traversal
    integer, allocatable :: stack(:)
    !> Total number of nodes and current stack position
    integer :: n, top

    n = tree%ndep
    allocate(visited(n), source=.false.)
    allocate(stack(n), source=0)
    top = 0

    !> Depth-First Search from root node
    call dfs(root_id,visited,stack,top,error)
    if (allocated(error)) return

    !> The final link order is the reverse of the DFS post-order
    allocate(order(top))
    if (top>0) order(:) = stack(:top)
    
  contains

    !> Recursive depth-first search, post-order
    recursive subroutine dfs(i,visited,stack,top,error)
        integer, intent(in) :: i
        logical, intent(inout) :: visited(:)
        integer, intent(inout) :: stack(:),top
        type(error_t), allocatable, intent(out) :: error
        integer :: k, id

        if (.not.(i>0 .and. i<=tree%ndep)) then 
            call fatal_error(error,'package graph failed: invalid dependency ID')
            return
        end if
        if (visited(i)) return
        
        visited(i) = .true.

        ! Visit all required dependencies before this node
        if (allocated(tree%dep(i)%package_dep)) then
            do k = 1, size(tree%dep(i)%package_dep)
                id = tree%find(tree%dep(i)%package_dep(k)%s)
                
                if (.not.(id>0 .and. id<=tree%ndep)) then 
                    call fatal_error(error,'package graph failed: cannot find '//tree%dep(i)%package_dep(k)%s)
                    return
                end if

                call dfs(id, visited, stack, top, error)
                if (allocated(error)) return
            end do
        end if

        ! Now that all dependencies are handled, record this node
        top = top + 1
        stack(top) = i
    end subroutine dfs

  end subroutine local_link_order

  !> Read dependency tree from file
  subroutine load_cache_from_file(self, file, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> File name
    character(len=*), intent(in) :: file
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    integer :: unit
    logical :: exist

    inquire (file=file, exist=exist)
    if (.not. exist) return

    open (file=file, newunit=unit)
    call self%load_cache(unit, error)
    close (unit)
  end subroutine load_cache_from_file

  !> Read dependency tree from file
  subroutine load_cache_from_unit(self, unit, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> File name
    integer, intent(in) :: unit
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    type(toml_error), allocatable :: parse_error
    type(toml_table), allocatable :: table

    call toml_load(table, unit, error=parse_error)

    if (allocated(parse_error)) then
      allocate (error)
      call move_alloc(parse_error%message, error%message)
      return
    end if

    call self%load_cache(table, error)
    if (allocated(error)) return

  end subroutine load_cache_from_unit

  !> Read dependency tree from TOML data structure
  subroutine load_cache_from_toml(self, table, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> Data structure
    type(toml_table), intent(inout) :: table
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    integer :: ndep, ii
    logical :: is_unix
    character(len=:), allocatable :: version, url, obj, rev, proj_dir
    type(toml_key), allocatable :: list(:)
    type(toml_table), pointer :: ptr

    call table%get_keys(list)

    ndep = size(self%dep)
    if (ndep < size(list) + self%ndep) then
      call resize(self%dep, ndep + ndep/2 + size(list))
    end if

    is_unix = get_os_type() /= OS_WINDOWS

    do ii = 1, size(list)
      call get_value(table, list(ii)%key, ptr)
      call get_value(ptr, "version", version)
      call get_value(ptr, "proj-dir", proj_dir)
      call get_value(ptr, "git", url)
      call get_value(ptr, "obj", obj)
      call get_value(ptr, "rev", rev)
      if (.not. allocated(proj_dir)) cycle
      self%ndep = self%ndep + 1
      associate (dep => self%dep(self%ndep))
        dep%name = list(ii)%key
        if (is_unix) then
          dep%proj_dir = proj_dir
        else
          dep%proj_dir = windows_path(proj_dir)
        end if
        dep%done = .false.
        if (allocated(version)) then
          if (.not. allocated(dep%version)) allocate (dep%version)
          call new_version(dep%version, version, error)
          if (allocated(error)) exit
        end if
        if (allocated(url)) then
          if (allocated(obj)) then
            dep%git = git_target_revision(url, obj)
          else
            dep%git = git_target_default(url)
          end if
          if (allocated(rev)) then
            dep%revision = rev
          end if
        else
          dep%path = proj_dir
        end if
      end associate
    end do
    if (allocated(error)) return

    self%ndep = size(list)
  end subroutine load_cache_from_toml

  !> Write dependency tree to file
  subroutine dump_cache_to_file(self, file, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> File name
    character(len=*), intent(in) :: file
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    integer :: unit

    open (file=file, newunit=unit)
    call self%dump_cache(unit, error)
    close (unit)
    if (allocated(error)) return

  end subroutine dump_cache_to_file

  !> Write dependency tree to file
  subroutine dump_cache_to_unit(self, unit, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> Formatted unit
    integer, intent(in) :: unit
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    type(toml_table) :: table

    table = toml_table()
    call self%dump_cache(table, error)

    write (unit, '(a)') toml_serialize(table)

  end subroutine dump_cache_to_unit

  !> Write dependency tree to TOML datastructure
  subroutine dump_cache_to_toml(self, table, error)
    !> Instance of the dependency tree
    class(dependency_tree_t), intent(inout) :: self
    !> Data structure
    type(toml_table), intent(inout) :: table
    !> Error handling
    type(error_t), allocatable, intent(out) :: error

    integer :: ii
    type(toml_table), pointer :: ptr
    character(len=:), allocatable :: proj_dir

    do ii = 1, self%ndep
      associate (dep => self%dep(ii))
        call add_table(table, dep%name, ptr)
        if (.not. associated(ptr)) then
          call fatal_error(error, "Cannot create entry for "//dep%name)
          exit
        end if
        if (allocated(dep%version)) then
          call set_value(ptr, "version", dep%version%s())
        end if
        proj_dir = canon_path(dep%proj_dir)
        call set_value(ptr, "proj-dir", proj_dir)
        if (allocated(dep%git)) then
          call set_value(ptr, "git", dep%git%url)
          if (allocated(dep%git%object)) then
            call set_value(ptr, "obj", dep%git%object)
          end if
          if (allocated(dep%revision)) then
            call set_value(ptr, "rev", dep%revision)
          end if
        end if
      end associate
    end do
    if (allocated(error)) return

  end subroutine dump_cache_to_toml

  !> Reallocate a list of dependencies
  pure subroutine resize_dependency_node(var, n)
    !> Instance of the array to be resized
    type(dependency_node_t), allocatable, intent(inout) :: var(:)
    !> Dimension of the final array size
    integer, intent(in), optional :: n

    type(dependency_node_t), allocatable :: tmp(:)
    integer :: this_size, new_size
    integer, parameter :: initial_size = 16

    if (allocated(var)) then
      this_size = size(var, 1)
      call move_alloc(var, tmp)
    else
      this_size = initial_size
    end if

    if (present(n)) then
      new_size = n
    else
      new_size = this_size + this_size/2 + 1
    end if

    allocate (var(new_size))

    if (allocated(tmp)) then
      this_size = min(size(tmp, 1), size(var, 1))
      var(:this_size) = tmp(:this_size)
      deallocate (tmp)
    end if

  end subroutine resize_dependency_node

  !> Check if a dependency node has changed
  logical function dependency_has_changed(cached, manifest, verbosity, iunit) result(has_changed)
    !> Two instances of the same dependency to be compared
    type(dependency_node_t), intent(in) :: cached, manifest

    !> Log verbosity
    integer, intent(in) :: verbosity, iunit

    integer :: ip

    has_changed = .true.

    !> All the following entities must be equal for the dependency to not have changed
    if (manifest_has_changed(cached=cached, manifest=manifest, verbosity=verbosity, iunit=iunit)) return

    !> For now, only perform the following checks if both are available. A dependency in cache.toml
    !> will always have this metadata; a dependency from fpm.toml which has not been fetched yet
    !> may not have it
    if (allocated(cached%version) .and. allocated(manifest%version)) then
      if (cached%version /= manifest%version) then
        if (verbosity > 1) write (iunit, out_fmt) "VERSION has changed: "//cached%version%s()//" vs. "//manifest%version%s()
        return
      end if
    else
      if (verbosity > 1) write (iunit, out_fmt) "VERSION has changed presence "
    end if
    if (allocated(cached%revision) .and. allocated(manifest%revision)) then
      if (cached%revision /= manifest%revision) then
        if (verbosity > 1) write (iunit, out_fmt) "REVISION has changed: "//cached%revision//" vs. "//manifest%revision
        return
      end if
    else
      if (verbosity > 1) write (iunit, out_fmt) "REVISION has changed presence "
    end if
    if (allocated(cached%proj_dir) .and. allocated(manifest%proj_dir)) then
      if (cached%proj_dir /= manifest%proj_dir) then
        if (verbosity > 1) write (iunit, out_fmt) "PROJECT DIR has changed: "//cached%proj_dir//" vs. "//manifest%proj_dir
        return
      end if
    else
      if (verbosity > 1) write (iunit, out_fmt) "PROJECT DIR has changed presence "
    end if
    if (allocated(cached%preprocess) .eqv. allocated(manifest%preprocess)) then
      if (allocated(cached%preprocess)) then
          if (size(cached%preprocess) /= size(manifest%preprocess)) then
            if (verbosity > 1) write (iunit, out_fmt) "PREPROCESS has changed size"
            return
          end if
          do ip=1,size(cached%preprocess)
             if (.not.(cached%preprocess(ip) == manifest%preprocess(ip))) then
                if (verbosity > 1) write (iunit, out_fmt) "PREPROCESS config has changed"
                return
             end if
          end do
      endif
    else
      if (verbosity > 1) write (iunit, out_fmt) "PREPROCESS has changed presence "
      return
    end if

    !> All checks passed: the two dependencies have no differences
    has_changed = .false.

  end function dependency_has_changed

  !> Check that two dependency nodes are equal
  logical function dependency_node_is_same(this,that)
      class(dependency_node_t), intent(in) :: this
      class(serializable_t), intent(in) :: that

      dependency_node_is_same = .false.

      select type (other=>that)
         type is (dependency_node_t)

            ! Base class must match
            if (.not.(this%dependency_config_t==other%dependency_config_t)) return

            ! Extension must match
            if (.not.(this%done  .eqv.other%done)) return
            if (.not.(this%update.eqv.other%update)) return
            if (.not.(this%cached.eqv.other%cached)) return

            if (allocated(this%proj_dir) .neqv. allocated(other%proj_dir)) return
            if (allocated(this%proj_dir)) then
              if (.not.(this%proj_dir==other%proj_dir)) return
            endif
            if (allocated(this%revision) .neqv. allocated(other%revision)) return
            if (allocated(this%revision)) then
              if (.not.(this%revision==other%revision)) return
            endif

            if (allocated(this%version).neqv.allocated(other%version)) return
            if (allocated(this%version)) then
              if (.not.(this%version==other%version)) return
            endif

            if (allocated(this%package_dep).neqv.allocated(other%package_dep)) return
            if (allocated(this%package_dep)) then
              if (.not.size(this%package_dep)==size(other%package_dep)) return
              if (.not.(this%package_dep==other%package_dep)) return
            endif
            
         class default
            ! Not the same type
            return
      end select

      !> All checks passed!
      dependency_node_is_same = .true.

  end function dependency_node_is_same

    !> Dump dependency to toml table
    subroutine node_dump_to_toml(self, table, error)

        !> Instance of the serializable object
        class(dependency_node_t), intent(inout) :: self

        !> Data structure
        type(toml_table), intent(inout) :: table

        !> Error handling
        type(error_t), allocatable, intent(out) :: error

        integer :: i,n,ierr
        type(toml_array), pointer :: array

        ! Dump parent class
        call self%dependency_config_t%dump_to_toml(table, error)
        if (allocated(error)) return

        if (allocated(self%version)) then
            call set_string(table, "version", self%version%s(), error,'dependency_node_t')
            if (allocated(error)) return
        endif
        call set_string(table, "proj-dir", self%proj_dir, error, 'dependency_node_t')
        if (allocated(error)) return
        call set_string(table, "revision", self%revision, error, 'dependency_node_t')
        if (allocated(error)) return
        call set_value(table, "done", self%done, error, 'dependency_node_t')
        if (allocated(error)) return
        call set_value(table, "update", self%update, error, 'dependency_node_t')
        if (allocated(error)) return
        call set_value(table, "cached", self%cached, error, 'dependency_node_t')
        if (allocated(error)) return        
        call set_list(table, "package-dep",self%package_dep, error)
        if (allocated(error)) return        
        
    end subroutine node_dump_to_toml

    !> Read dependency from toml table (no checks made at this stage)
    subroutine node_load_from_toml(self, table, error)

        !> Instance of the serializable object
        class(dependency_node_t), intent(inout) :: self

        !> Data structure
        type(toml_table), intent(inout) :: table

        !> Error handling
        type(error_t), allocatable, intent(out) :: error

        !> Local variables
        character(len=:), allocatable :: version
        integer :: ierr,i,n
        type(toml_array), pointer :: array

        call destroy_dependency_node(self)

        ! Load parent class
        call self%dependency_config_t%load_from_toml(table, error)
        if (allocated(error)) return

        call get_value(table, "done", self%done, error, 'dependency_node_t')
        if (allocated(error)) return
        call get_value(table, "update", self%update, error, 'dependency_node_t')
        if (allocated(error)) return
        call get_value(table, "cached", self%cached, error, 'dependency_node_t')
        if (allocated(error)) return

        call get_value(table, "proj-dir", self%proj_dir)
        call get_value(table, "revision", self%revision)

        call get_value(table, "version", version)
        if (allocated(version)) then
            allocate(self%version)
            call new_version(self%version, version, error)
            if (allocated(error)) then
                error%message = 'dependency_node_t: version error from TOML table - '//error%message
                return
            endif
        end if        
        
        call get_list(table,"package-dep",self%package_dep, error)
        if (allocated(error)) return        
        
    end subroutine node_load_from_toml

    !> Destructor
    elemental subroutine destroy_dependency_node(self)

        class(dependency_node_t), intent(inout) :: self

        integer :: ierr

        call dependency_destroy(self)

        deallocate(self%version,stat=ierr)
        deallocate(self%proj_dir,stat=ierr)
        deallocate(self%revision,stat=ierr)
        deallocate(self%package_dep,stat=ierr)
        self%done = .false.
        self%update = .false.
        self%cached = .false.

    end subroutine destroy_dependency_node

  !> Check that two dependency trees are equal
  logical function dependency_tree_is_same(this,that)
    class(dependency_tree_t), intent(in) :: this
    class(serializable_t), intent(in) :: that

    integer :: ii

    dependency_tree_is_same = .false.

    select type (other=>that)
       type is (dependency_tree_t)

          if (.not.(this%unit==other%unit)) return
          if (.not.(this%verbosity==other%verbosity)) return
          if (allocated(this%dep_dir) .neqv. allocated(other%dep_dir)) return
          if (allocated(this%dep_dir)) then
            if (.not.(this%dep_dir==other%dep_dir)) return
          endif
          if (.not.(this%ndep==other%ndep)) return
          if (.not.(allocated(this%dep).eqv.allocated(other%dep))) return
          if (allocated(this%dep)) then
             if (.not.(size(this%dep)==size(other%dep))) return
             do ii = 1, size(this%dep)
                if (.not.(this%dep(ii)==other%dep(ii))) return
             end do
          endif
          if (allocated(this%cache) .neqv. allocated(other%cache)) return
          if (allocated(this%cache)) then
            if (.not.(this%cache==other%cache)) return
          endif

       class default
          ! Not the same type
          return
    end select

    !> All checks passed!
    dependency_tree_is_same = .true.

  end function dependency_tree_is_same

    !> Dump dependency to toml table
    subroutine tree_dump_to_toml(self, table, error)

        !> Instance of the serializable object
        class(dependency_tree_t), intent(inout) :: self

        !> Data structure
        type(toml_table), intent(inout) :: table

        !> Error handling
        type(error_t), allocatable, intent(out) :: error

        integer :: ierr, ii
        type(toml_table), pointer :: ptr_deps,ptr
        character(27) :: unnamed

        call set_value(table, "unit", self%unit, error, 'dependency_tree_t')
        if (allocated(error)) return
        call set_value(table, "verbosity", self%verbosity, error, 'dependency_tree_t')
        if (allocated(error)) return
        call set_string(table, "dep-dir", self%dep_dir, error, 'dependency_tree_t')
        if (allocated(error)) return
        call set_string(table, "cache", self%cache, error, 'dependency_tree_t')
        if (allocated(error)) return
        call set_value(table, "ndep", self%ndep, error, 'dependency_tree_t')
        if (allocated(error)) return

        if (allocated(self%dep)) then

           ! Create dependency table
           call add_table(table, "dependencies", ptr_deps)
           if (.not. associated(ptr_deps)) then
              call fatal_error(error, "dependency_tree_t cannot create dependency table ")
              return
           end if

           do ii = 1, size(self%dep)
              associate (dep => self%dep(ii))

                 !> Because dependencies are named, fallback if this has no name
                 !> So, serialization will work regardless of size(self%dep) == self%ndep
                 if (.not. allocated(dep%name)) then
                    write(unnamed,1) ii
                    call add_table(ptr_deps, trim(unnamed), ptr)
                 else if (len_trim(dep%name)==0) then
                    write(unnamed,1) ii
                    call add_table(ptr_deps, trim(unnamed), ptr)
                 else
                    call add_table(ptr_deps, dep%name, ptr)
                 end if
                 if (.not. associated(ptr)) then
                    call fatal_error(error, "dependency_tree_t cannot create entry for dependency "//dep%name)
                    return
                 end if
                 call dep%dump_to_toml(ptr, error)
                 if (allocated(error)) return
              end associate
           end do

        endif

        1 format('UNNAMED_DEPENDENCY_',i0)

    end subroutine tree_dump_to_toml

    !> Read dependency from toml table (no checks made at this stage)
    subroutine tree_load_from_toml(self, table, error)

        !> Instance of the serializable object
        class(dependency_tree_t), intent(inout) :: self

        !> Data structure
        type(toml_table), intent(inout) :: table

        !> Error handling
        type(error_t), allocatable, intent(out) :: error

        !> Local variables
        type(toml_key), allocatable :: keys(:),dep_keys(:)
        type(toml_table), pointer :: ptr_deps,ptr
        integer :: ii, jj, ierr

        call table%get_keys(keys)

        call get_value(table, "unit", self%unit, error, 'dependency_tree_t')
        if (allocated(error)) return
        call get_value(table, "verbosity", self%verbosity, error, 'dependency_tree_t')
        if (allocated(error)) return
        call get_value(table, "ndep", self%ndep, error, 'dependency_tree_t')
        if (allocated(error)) return
        call get_value(table, "dep-dir", self%dep_dir)
        call get_value(table, "cache", self%cache)

        find_deps_table: do ii = 1, size(keys)
            if (keys(ii)%key=="dependencies") then

               call get_value(table, keys(ii), ptr_deps)
               if (.not.associated(ptr_deps)) then
                  call fatal_error(error,'dependency_tree_t: error retrieving dependency table from TOML table')
                  return
               end if

               !> Read all dependencies
               call ptr_deps%get_keys(dep_keys)
               call resize(self%dep, size(dep_keys))

               do jj = 1, size(dep_keys)

                   call get_value(ptr_deps, dep_keys(jj), ptr)
                   call self%dep(jj)%load_from_toml(ptr, error)
                   if (allocated(error)) return

               end do

               exit find_deps_table

            endif
        end do find_deps_table

    end subroutine tree_load_from_toml


end module fpm_dependency
