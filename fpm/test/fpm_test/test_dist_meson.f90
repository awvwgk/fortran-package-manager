
module test_dist_meson
    use testsuite, only : new_unittest, unittest_t, error_t, test_failed, &
        & check_string
    use fpm_environment, only : OS_WINDOWS, OS_LINUX
    use fpm_filesystem, only : join_path
    use fpm_dist_meson
    implicit none
    private

    public :: collect_dist_meson


contains


    !> Collect all exported unit tests
    subroutine collect_dist_meson(testsuite)
        !> Collection of tests
        type(unittest_t), allocatable, intent(out) :: testsuite(:)

        testsuite = [ &
            & new_unittest("configure-output", test_configure_output)]

    end subroutine collect_dist_meson


    subroutine test_configure_output(error)
        !> Error handling
        type(error_t), allocatable, intent(out) :: error

        character(len=:), allocatable :: output

    end subroutine test_configure_output


end module test_dist_meson
