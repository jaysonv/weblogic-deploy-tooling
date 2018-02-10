@ECHO OFF
@rem **************************************************************************
@rem discoverDomain.cmd
@rem
@rem Copyright (c) 2017, 2018, Oracle and/or its affiliates. All rights reserved.
@rem The Universal Permissive License (UPL), Version 1.0
@rem
@rem     NAME
@rem       discoverDomain.cmd - WLS Deploy tool to discover a domain.
@rem
@rem     DESCRIPTION
@rem       This script discovers the model of an existing domain and gathers
@rem       the binaries needed to recreate the domain elsewhere with all of
@rem       its applications and resources configured.
@rem
@rem
@rem This script uses the following command-line arguments directly, the rest
@rem of the arguments are passed down to the underlying python program:
@rem
@rem     - -oracle_home        The directory of the existing Oracle Home to use.
@rem                           This directory must exist and it is the caller^'s
@rem                           responsibility to verify that it does. This
@rem                           argument is required.
@rem
@rem     - -domain_type        The type of domain to create. This argument is
@rem                           is optional.  If not specified, it defaults to WLS.
@rem
@rem     - -wlst_path          The path to the Oracle Home product directory under
@rem                           which to find the wlst.cmd script.  This is only
@rem                           needed for pre-12.2.1 upper stack products like SOA.
@rem
@rem                           For example, for SOA 12.1.3, -wlst_path should be
@rem                           specified as %ORACLE_HOME%\soa
@rem
@rem This script uses the following variables:
@rem
@rem JAVA_HOME            - The location of the JDK to use.  The caller must set
@rem                        this variable to a valid Java 7 (or later) JDK.
@rem
@rem WLSDEPLOY_HOME        - The location of the WLS Deploy installation.
@rem                         If the caller sets this, the callers location will be
@rem                         honored provided it is an existing directory.
@rem                         Otherwise, the location will be calculated from the
@rem                         location of this script.
@rem
@rem WLSDEPLOY_PROPERTIES  - Extra system properties to pass to WLST.  The caller
@rem                         can use this environment variable to add additional
@rem                         system properties to the WLST environment.
@rem

SETLOCAL

SET WLSDEPLOY_PROGRAM_NAME=discoverDomain

SET SCRIPT_PATH=%~dp0
FOR %%i IN ("%SCRIPT_PATH%") DO SET SCRIPT_PATH=%%~fsi
IF %SCRIPT_PATH:~-1%==\ SET SCRIPT_PATH=%SCRIPT_PATH:~0,-1%

IF NOT DEFINED WLSDEPLOY_HOME (
  SET WLSDEPLOY_HOME=%SCRIPT_PATH%\..
) ELSE (
  IF NOT EXIST "%WLSDEPLOY_HOME%" (
    ECHO Specified WLSDEPLOY_HOME of "%WLSDEPLOY_HOME%" does not exist >&2
    SET RETURN_CODE=2
    GOTO exit_script
  )
)
FOR %%i IN ("%WLSDEPLOY_HOME%") DO SET WLSDEPLOY_HOME=%%~fsi
IF %WLSDEPLOY_HOME:~-1%==\ SET WLSDEPLOY_HOME=%WLSDEPLOY_HOME:~0,-1%

@rem
@rem Make sure that the JAVA_HOME environment variable is set to point to a
@rem JDK 7 or higher JVM (and that it isn't OpenJDK).
@rem
IF NOT DEFINED JAVA_HOME (
  ECHO Please set the JAVA_HOME environment variable to point to a Java 7 installation >&2
  SET RETURN_CODE=2
  GOTO exit_script
) ELSE (
  IF NOT EXIST "%JAVA_HOME%" (
    ECHO Your JAVA_HOME environment variable to points to a non-existent directory: %JAVA_HOME% >&2
    SET RETURN_CODE=2
    GOTO exit_script
  )
)
FOR %%i IN ("%JAVA_HOME%") DO SET JAVA_HOME=%%~fsi
IF %JAVA_HOME:~-1%==\ SET JAVA_HOME=%JAVA_HOME:~0,-1%

IF EXIST %JAVA_HOME%\bin\java.exe (
  FOR %%i IN ("%JAVA_HOME%\bin\java.exe") DO SET JAVA_EXE=%%~fsi
) ELSE (
  ECHO Java executable does not exist at %JAVA_HOME%\bin\java.exe does not exist >&2
  SET RETURN_CODE=2
  GOTO exit_script
)

FOR /F %%i IN ('%JAVA_EXE% -version 2^>^&1') DO (
  IF "%%i" == "OpenJDK" (
    ECHO JAVA_HOME %JAVA_HOME% contains OpenJDK^, which is not supported >&2
    SET RETURN_CODE=2
    GOTO exit_script
  )
)

FOR /F tokens^=2-5^ delims^=.-_^" %%j IN ('%JAVA_EXE% -fullversion 2^>^&1') DO (
  SET "JVM_FULL_VERSION=%%j.%%k.%%l_%%m"
  SET "JVM_VERSION=%%k"
)

IF %JVM_VERSION% LSS 7 (
  ECHO You are using an unsupported JDK version %JVM_FULL_VERSION% >&2
  SET RETURN_CODE=2
  GOTO exit_script
) ELSE (
  ECHO JDK version is %JVM_FULL_VERSION%, setting JAVA_VENDOR to Sun...
  SET JAVA_VENDOR=Sun
)

@rem
@rem Find the args required to determine the WLST script to run
@rem

SET ORACLE_HOME=
SET DOMAIN_TYPE=
SET WLST_PATH_DIR=

:arg_loop
IF "%1" == "-oracle_home" (
  SET ORACLE_HOME=%2
  SHIFT
  GOTO arg_continue
)
IF "%1" == "-domain_type" (
  SET DOMAIN_TYPE=%2
  SHIFT
  GOTO arg_continue
)
IF "%1" == "-wlst_path" (
  SET WLST_PATH_DIR=%2
  SHIFT
  GOTO arg_continue
)
@REM If none of the above, unknown argument so skip it
:arg_continue
SHIFT
IF NOT "%~1" == "" (
  GOTO arg_loop
)

@rem
@rem Check for values of required arguments for this script to continue.
@rem The underlying WLST script has other required arguments.
@rem
IF "%ORACLE_HOME%" == "" (
  ECHO Required argument ORACLE_HOME not provided >&2
  SET RETURN_CODE=99
  GOTO usage
)

@rem
@rem If the WLST_PATH_DIR is specified, validate that it contains the wlst.cmd script
@rem
IF DEFINED WLST_PATH_DIR (
  FOR %%i IN ("%WLST_PATH_DIR%") DO SET WLST_PATH_DIR=%%~fsi
  IF NOT EXIST "%WLST_PATH_DIR%" (
    ECHO WLST_PATH_DIR specified does not exist: %WLST_PATH_DIR% >&2
    SET RETURN_CODE=98
    GOTO exit_script
  )
  set "WLST=%WLST_PATH_DIR\common\bin\wlst.cmd"
  IF NOT EXIST "%WLST%" (
    ECHO WLST executable %WLST% not found under specified WLST_PATH_DIR %WLST_PATH_DIR% >&2
    SET RETURN_CODE=98
    GOTO exit_script
  )
  GOTO found_wlst
)

@rem
@rem Find the location for wlst.cmd
@rem
SET WLST=
SET USE_JRF_WLST=FALSE
IF DEFINED DOMAIN_TYPE (
  IF "%DOMAIN_TYPE%" == "WLS" (
    SET USE_JRF_WLST=FALSE
    GOTO domain_type_recognized
  )
  IF "%DOMAIN_TYPE%" == "RestrictedJRF" (
    SET USE_JRF_WLST=TRUE
    GOTO domain_type_recognized
  )
  IF "%DOMAIN_TYPE%" == "JRF" (
    SET USE_JRF_WLST=TRUE
    GOTO domain_type_recognized
  )
  ECHO Domain type %DOMAIN_TYPE% not recognized by shell script...assuming JRF is required
  SET USE_JRF_WLST=TRUE
)

:domain_type_recognized
IF "%USE_JRF_WLST%" == "TRUE" (
    IF EXIST "%ORACLE_HOME%\oracle_common\common\bin\wlst.cmd" (
        SET WLST=%ORACLE_HOME%\oracle_common\common\bin\wlst.cmd
        SET CLASSPATH=%WLSDEPLOY_HOME%\lib\weblogic-deploy-core.jar
        SET WLST_EXT_CLASSPATH=%WLSDEPLOY_HOME%\lib\weblogic-deploy-core.jar
        GOTO found_wlst
    )
) ELSE (
    IF EXIST "%ORACLE_HOME%\wlserver_10.3\common\bin\wlst.cmd" (
        SET WLST=%ORACLE_HOME%\wlserver_10.3\common\bin\wlst.cmd
        SET CLASSPATH=%WLSDEPLOY_HOME%\lib\weblogic-deploy-core.jar
        GOTO found_wlst
    )
    IF EXIST "%ORACLE_HOME%\wlserver_12.1\common\bin\wlst.cmd" (
        SET WLST=%ORACLE_HOME%\wlserver_12.1\common\bin\wlst.cmd
        SET CLASSPATH=%WLSDEPLOY_HOME%\lib\weblogic-deploy-core.jar
        GOTO found_wlst
    )
    IF EXIST "%ORACLE_HOME%\wlserver\common\bin\wlst.cmd" (
        IF EXIST "%ORACLE_HOME%\wlserver\.product.properties" (
            @rem WLS 12.1.2 or WLS 12.1.3
            SET WLST=%ORACLE_HOME%\wlserver\common\bin\wlst.cmd
            SET CLASSPATH=%WLSDEPLOY_HOME%\lib\weblogic-deploy-core.jar
        ) ELSE (
            @rem WLS 12.2.1+
            SET WLST=%ORACLE_HOME%\oracle_common\common\bin\wlst.cmd
            SET WLST_EXT_CLASSPATH=%WLSDEPLOY_HOME%\lib\weblogic-deploy-core.jar
        )
        GOTO found_wlst
    )
)

IF NOT EXIST "%WLST%" (
  ECHO Unable to locate wlst.cmd script in ORACLE_HOME %ORACLE_HOME% >&2
  SET RETURN_CODE=98
  GOTO exit_script
)
:found_wlst

SET LOG_CONFIG_CLASS=oracle.weblogic.deploy.logging.WLSDeployLoggingConfig
SET WLST_PROPERTIES=-Dcom.oracle.cie.script.throwException=true
SET "WLST_PROPERTIES=-Djava.util.logging.config.class=%LOG_CONFIG_CLASS% %WLST_PROPERTIES%"
SET "WLST_PROPERTIES=%WLST_PROPERTIES% %WLSDEPLOY_PROPERTIES%"

IF NOT DEFINED WLSDEPLOY_LOG_PROPERTIES (
  SET WLSDEPLOY_LOG_PROPERTIES=%WLSDEPLOY_HOME%\etc\logging.properties
)
IF NOT DEFINED WLSDEPLOY_LOG_DIRECTORY (
  SET WLSDEPLOY_LOG_DIRECTORY=%WLSDEPLOY_HOME%\logs
)

ECHO JAVA_HOME = %JAVA_HOME%
ECHO WLST_EXT_CLASSPATH = %WLST_EXT_CLASSPATH%
ECHO CLASSPATH = %CLASSPATH%
ECHO WLST_PROPERTIES = %WLST_PROPERTIES%

SET PY_SCRIPTS_PATH=%WLSDEPLOY_HOME%\lib\python

ECHO %WLST% "%PY_SCRIPTS_PATH%\discover.py" %*

"%WLST%" "%PY_SCRIPTS_PATH%\discover.py" %*

SET RETURN_CODE=%ERRORLEVEL%
IF "%RETURN_CODE%" == "100" (
  GOTO usage
)
IF "%RETURN_CODE%" == "99" (
  GOTO usage
)
IF "%RETURN_CODE%" == "98" (
  ECHO.
  ECHO discoverDomain.cmd failed due to a parameter validation error >&2
  GOTO exit_script
)
IF "%RETURN_CODE%" == "2" (
  ECHO.
  ECHO discoverDomain.cmd failed ^(exit code = %RETURN_CODE%^)
  GOTO exit_script
)
IF "%RETURN_CODE%" == "1" (
  ECHO.
  ECHO discoverDomain.cmd completed but with some issues ^(exit code = %RETURN_CODE%^) >&2
  GOTO exit_script
)
IF "%RETURN_CODE%" == "0" (
  ECHO.
  ECHO discoverDomain.cmd completed successfully ^(exit code = %RETURN_CODE%^)
  GOTO exit_script
)
@rem Unexpected return code so just print the message and exit...
ECHO.
ECHO discoverDomain.cmd failed ^(exit code = %RETURN_CODE%^) >&2
GOTO exit_script

:usage
ECHO.
:usage
ECHO.
ECHO Usage: %~nx0 -oracle_home ^<oracle-home^>
ECHO              -domain_home ^<domain-home^>
ECHO              -archive_file ^<archive-file^>
ECHO              [-model_file ^<model-file^>]
ECHO              [-domain_type ^<domain-type^>]
ECHO              [-wlst_path ^<wlst-path^>]
ECHO              [-admin_url ^<admin-url^>
ECHO               -admin_user ^<admin-user^>
ECHO              ]
ECHO.
ECHO     where:
ECHO         oracle-home    - the existing Oracle Home directory for the domain
ECHO.
ECHO         domain-home    - the domain home directory
ECHO.
ECHO         archive-file   - the path to the archive file to create
ECHO.
ECHO         model-file     - the location to write the model file,
ECHO                          the default is to write it inside the archive
ECHO.
ECHO         domain-type    - the type of domain (e.g., WLS, JRF).
ECHO                          used to locate wlst.cmd if wlst-path not specified
ECHO.
ECHO         wlst-path      - the Oracle Home subdirectory of the wlst.cmd
ECHO                          script to use (e.g., ^<ORACLE_HOME^>\soa)
ECHO.
ECHO         admin-url      - the admin server URL (used for online discovery)
ECHO.
ECHO         admin-user     - the admin username (used for online discovery)
ECHO.

:exit_script
IF DEFINED USE_CMD_EXIT (
  EXIT %RETURN_CODE%
) ELSE (
  EXIT /B %RETURN_CODE%
)

ENDLOCAL