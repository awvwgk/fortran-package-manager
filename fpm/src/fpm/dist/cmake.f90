!> Handling of distribution of projects as standalone CMake project.
module fpm_dist_cmake
  use fpm_error, only : error_t, fatal_error
  implicit none
  private

  public :: create_cmake_dist

  character, parameter :: nl = new_line('a')

  !> Content of the cmake package configuration input
  character(len=*), parameter :: cmake_config_in = &
    '@PACKAGE_INIT@' //nl//&
    '' //nl//&
    'include(CMakeFindDependencyMacro)' //nl//&
    '' //nl//&
    'if(NOT TARGET "@PROJECT_NAME@::@PROJECT_NAME@")' //nl//&
    '  include("${CMAKE_CURRENT_LIST_DIR}/@PROJECT_NAME@-targets.cmake")' //nl//&
    'endif()'

  !> Minimum required CMake version for generated lists
  character(len=*), parameter :: cmake_minimum_required = &
    'cmake_minimum_required(VERSION 3.16)'

  !> Content of the project CMake lists, contains install and target export
  character(len=*), parameter :: main_cmake_lists_txt = &
    'include(GNUInstallDirs)' //nl//&
    'include(CMakePackageConfigHelpers)' //nl//&
    '' //nl//&
    'add_library(' //nl//&
    '  "${PROJECT_NAME}"' //nl//&
    '  INTERFACE' //nl//&
    ')' //nl//&
    'target_link_libraries(' //nl//&
    '  "${PROJECT_NAME}"' //nl//&
    '  INTERFACE "${PROJECT_NAME}-lib"' //nl//&
    ')' //nl//&
    'install(' //nl//&
    '  TARGETS "${PROJECT_NAME}"' //nl//&
    '  EXPORT "${PROJECT_NAME}-targets"' //nl//&
    ')' //nl//&
    '' //nl//&
    'install(' //nl//&
    '  EXPORT "${PROJECT_NAME}-targets"' //nl//&
    '  FILE "${PROJECT_NAME}-targets.cmake"' //nl//&
    '  NAMESPACE "${PROJECT_NAME}::"' //nl//&
    '  DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/${PROJECT_NAME}"' //nl//&
    ')' //nl//&
    '' //nl//&
    'configure_package_config_file(' //nl//&
    '  "${PROJECT_SOURCE_DIR}/config.cmake.in"' //nl//&
    '  "${PROJECT_BINARY_DIR}/${PROJECT_NAME}-config.cmake"' //nl//&
    '  INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/${PROJECT_NAME}"' //nl//&
    ')' //nl//&
    '' //nl//&
    'write_basic_package_version_file(' //nl//&
    '  "${PROJECT_BINARY_DIR}/${PROJECT_NAME}-config-version.cmake"' //nl//&
    '  VERSION "${PROJECT_VERSION}"' //nl//&
    '  COMPATIBILITY SameMajorVersion' //nl//&
    ')' //nl//&
    '' //nl//&
    'install(' //nl//&
    '  FILES' //nl//&
    '  "${PROJECT_BINARY_DIR}/${PROJECT_NAME}-config.cmake"' //nl//&
    '  "${PROJECT_BINARY_DIR}/${PROJECT_NAME}-config-version.cmake"' //nl//&
    '  DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/${PROJECT_NAME}"' //nl//&
    ')'

  !> Content of the library CMake lists, contains install and target export
  character(len=*), parameter :: lib_cmake_lists_txt = &
    'add_library(' //nl// &
    '  "${PROJECT_NAME}-lib"' //nl// &
    '  "${srcs}"' //nl// &
    ')' //nl// &
    '' //nl// &
    'set_target_properties(' //nl// &
    '  "${PROJECT_NAME}-lib"' //nl// &
    '  PROPERTIES' //nl// &
    '  Fortran_MODULE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/include"' //nl// &
    ')' //nl// &
    'target_include_directories(' //nl// &
    '  "${PROJECT_NAME}-lib"' //nl// &
    '  $<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}/include>' //nl// &
    '  $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>' //nl// &
    ')' //nl// &
    'install(' //nl// &
    '  TARGETS "${PROJECT_NAME}-lib"' //nl// &
    '  EXPORT "${PROJECT_NAME}-targets"' //nl// &
    '  ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"' //nl// &
    '  LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"' //nl// &
    ')' //nl// &
    'install(' //nl// &
    '  DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/include"' //nl// &
    '  DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"' //nl// &
    ')'

contains


!> Create a CMake project for distribution
subroutine create_cmake_dist(prefix)
  character(len=*), intent(in) :: prefix
end subroutine create_cmake_dist


end module fpm_dist_cmake
