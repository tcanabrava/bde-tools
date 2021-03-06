if(WAFSTYLEOUT_INCLUDED)
    return()
endif()
set(WAFSTYLEOUT_INCLUDED true)

find_package(PythonInterp REQUIRED)

function(internal_setup_wafstyleout)
    set(absolutePyFilename ${CMAKE_CURRENT_LIST_DIR}/wafstyleout.py)
    set_property(GLOBAL PROPERTY RULE_LAUNCH_COMPILE "${PYTHON_EXECUTABLE} ${absolutePyFilename}")
    set_property(GLOBAL PROPERTY RULE_LAUNCH_LINK "${PYTHON_EXECUTABLE} ${absolutePyFilename}")
        # The compiler/linker launchers need a string
	set_property(GLOBAL PROPERTY BDE_RULE_LAUNCH_TEST ${PYTHON_EXECUTABLE} ${absolutePyFilename})
        # The test launcher needs a list
endfunction()

option(BDE_USE_WAFSTYLEOUT "Use waf-style output wrapper" OFF)
if (BDE_USE_WAFSTYLEOUT)
    internal_setup_wafstyleout() # Call immediately for correctness of ${CMAKE_CURRENT_LIST_DIR}
endif()
