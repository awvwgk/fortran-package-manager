!> Command to generate standalone source code distributions of fpm projects.
module fpm_cmd_dist
  use, intrinsic :: iso_fortran_env, only : output_unit, error_unit
  use fpm, only : build_model
  use fpm_command_line, only : fpm_dist_settings
  use fpm_dist_meson
  use fpm_dist_source
  use fpm_error, only : error_t, fatal_error
  use fpm_installer, only : installer_t, new_installer
  use fpm_manifest, only : package_config_t, get_package_data
  use fpm_model, only : fpm_model_t
  use fpm_strings, only : string_t, str_ends_with
  implicit none
  private

  public :: cmd_dist

contains

  !> Entry point for the dist(ribute) command
  subroutine cmd_dist(settings)
    !> Representation of the command-line settings
    type(fpm_dist_settings), intent(in) :: settings

    type(package_config_t) :: package
    type(fpm_model_t) :: model
    type(installer_t) :: installer
    type(error_t), allocatable :: error
    type(meson_dist_t) :: meson
    type(source_dist_t) :: dist
    character(len=:), allocatable :: output
    integer :: i

    call get_package_data(package, "fpm.toml", error, apply_defaults=.true.)
    call handle_error(error)

    call new_installer(installer, prefix="dist", &
      verbosity=merge(1, 0, settings%verbose))
    call build_model(model, settings%fpm_build_settings, package, error)
    call handle_error(error)

    if (settings%meson) then
      call new_meson_dist(meson)
      call meson%create_dist(package, model%deps, installer, error)
      call handle_error(error)
    else
      call fatal_error(error, "Selected distribution method not implemented")
      call handle_error(error)
    end if

  end subroutine cmd_dist

  pure function filter_all(string) result(filter)
    character(len=*), intent(in) :: string
    logical :: filter
    filter = str_ends_with(string, ".f90") .or. str_ends_with(string, ".F90") &
       &.or. str_ends_with(string, ".c") .or. str_ends_with(string, ".h")
  end function filter_all

  !> Handler for runtime-errors
  subroutine handle_error(error)
    !> Error to handle
    type(error_t), intent(in), optional :: error
    if (present(error)) then
      write(error_unit, '(a)') error%message
      error stop
    end if
  end subroutine handle_error

end module fpm_cmd_dist
