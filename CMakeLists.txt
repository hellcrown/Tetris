cmake_minimum_required(VERSION 3.16)

project(Tetris VERSION 1.0 LANGUAGES CXX)

find_package(Qt6 6.5 REQUIRED COMPONENTS
    Quick
    QuickControls2
    Network
)

qt_standard_project_setup()

set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

qt_add_executable(Tetris
    MANUAL_FINALIZATION
    main.cpp
)

qt_add_qml_module(Tetris
    URI Tetris
    VERSION 1.0
    QML_FILES
        Main.qml
    RESOURCES
        image.jpg
        certs/isrgrootx1.pem
)

# 可解锁背景：backgrounds/ 下命名 bg1.jpg ~ bg12.jpg，构建时自动打包（qrc:/bgN.jpg）
# CONFIGURE_DEPENDS：新增/删除图片后构建系统自动重新 glob，无需手动重跑 CMake
file(GLOB TETRIS_BACKGROUNDS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/backgrounds/*.jpg")
if(TETRIS_BACKGROUNDS)
    qt_add_resources(Tetris "tetris_backgrounds"
        PREFIX "/"
        BASE "${CMAKE_CURRENT_SOURCE_DIR}/backgrounds"
        FILES ${TETRIS_BACKGROUNDS})
endif()

set_target_properties(Tetris PROPERTIES
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

if(ANDROID)
    set_target_properties(Tetris PROPERTIES
        QT_ANDROID_MIN_SDK_VERSION 23
        QT_ANDROID_TARGET_SDK_VERSION 33
        QT_ANDROID_PACKAGE_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/android
        QT_ANDROID_PACKAGE_NAME "org.qtproject.tetris"   # ← 与 AndroidManifest.xml 保持一致
    )
endif()

target_link_libraries(Tetris
    PRIVATE
        Qt6::Quick
        Qt6::QuickControls2
        Qt6::Network
)

qt_finalize_executable(Tetris)

include(GNUInstallDirs)
install(TARGETS Tetris
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
