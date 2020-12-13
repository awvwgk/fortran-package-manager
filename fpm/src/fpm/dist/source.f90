!> Basic distribution module to collect source code from a project.
module fpm_dist_source
  use fpm_filesystem, only : list_files
  use fpm_strings, only : string_t, resize
  implicit none
  private

  public :: source_dist_t, new_source_dist
  public :: filter_interface

  type :: source_dist_t
    integer :: nsrc = 0
    type(string_t), allocatable :: sources(:)
  contains
    procedure :: add_dir
    procedure :: add_file
  end type source_dist_t


  abstract interface
    pure function filter_interface(string) result(filter)
      character(len=*), intent(in) :: string
      logical :: filter
    end function filter_interface
  end interface

  integer, parameter :: initial_size = 16

contains

  subroutine new_source_dist(self)
    type(source_dist_t), intent(out) :: self

    self%nsrc = 0
    call resize(self%sources)

  end subroutine new_source_dist

  subroutine add_dir(self, path, filter)
    class(source_dist_t), intent(inout) :: self
    character(len=*), intent(in) :: path
    procedure(filter_interface) :: filter

    type(string_t), allocatable :: file_names(:)
    integer :: i

    call list_files(path, file_names, recurse=.true.)

    do i = 1, size(file_names)
      if (filter(file_names(i)%s)) then
        call self%add_file(file_names(i)%s)
      end if
    end do

  end subroutine add_dir

  subroutine add_file(self, path)
    class(source_dist_t), intent(inout) :: self
    character(len=*), intent(in) :: path

    if (self%nsrc >= size(self%sources)) call resize(self%sources)
    self%nsrc = self%nsrc + 1
    self%sources(self%nsrc)%s = path

  end subroutine add_file

end module fpm_dist_source
