# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-strict

import argparse
import logging
import os
import shutil
import sys
import time
import traceback
from typing import Type  # noqa

from . import (
    assert_writable_directory,
    buck,
    commands,
    find_log_directory,
    get_binary_version_from_file,
    is_capable_terminal,
    log,
    log_statistics,
    readable_directory,
    resolve_analysis_directory,
    switch_root,
    translate_arguments,
)
from .commands import (  # noqa
    Command,
    ExitCode,
    IncrementalStyle,
    ProfileOutput,
    reporting,
)
from .configuration import Configuration
from .exceptions import EnvironmentException
from .filesystem import AnalysisDirectory
from .version import __version__


LOG = logging.getLogger(__name__)  # type: logging.Logger


def main() -> int:
    def executable_file(file_path: str) -> str:
        if not os.path.isfile(file_path):
            raise EnvironmentException("%s is not a valid file" % file_path)
        if not os.access(file_path, os.X_OK):
            raise EnvironmentException("%s is not an executable file" % file_path)
        return file_path

    def writable_directory(path: str) -> str:
        # Create the directory if it does not exist.
        try:
            os.makedirs(path)
        except FileExistsError:
            pass
        assert_writable_directory(path)
        return path

    def file_exists(path: str) -> str:
        if not os.path.exists(path):
            raise argparse.ArgumentTypeError("ERROR: " + str(path) + " does not exist")
        return path

    parser = argparse.ArgumentParser(
        allow_abbrev=False,
        formatter_class=argparse.RawTextHelpFormatter,
        epilog="environment variables:"
        "\n   `PYRE_BINARY` overrides the pyre binary used."
        "\n   `PYRE_VERSION_HASH` overrides the pyre version set in the "
        "configuration files.",
    )

    parser.add_argument(
        "-l", "--local-configuration", type=str, help="Use a local configuration"
    )

    parser.add_argument(
        "--version",
        action="store_true",
        help="Print the client and binary versions of Pyre.",
    )

    parser.add_argument("--debug", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--sequential", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--strict", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--additional-check", action="append", help=argparse.SUPPRESS)

    parser.add_argument(
        "--show-error-traces",
        action="store_true",
        help="Display errors trace information",
    )

    # Logging.
    parser.add_argument(
        "--output",
        choices=[commands.reporting.TEXT, commands.reporting.JSON],
        default=commands.reporting.TEXT,
        help="How to format output",
    )
    parser.add_argument("--verbose", action="store_true", help="Enable verbose logging")
    parser.add_argument(
        "--enable-profiling", action="store_true", help=argparse.SUPPRESS
    )
    parser.add_argument(
        "-n",
        "--noninteractive",
        action="store_true",
        help="Disable interactive logging",
    )
    parser.add_argument(
        "--hide-parse-errors",
        action="store_true",
        help="Hide detailed information about parse errors",
    )
    parser.add_argument(
        "--show-parse-errors",
        action="store_true",
        help="[DEPRECATED] Show detailed information about parse errors",
    )
    parser.add_argument(
        "--logging-sections", help=argparse.SUPPRESS  # Enable sectional logging.
    )
    parser.add_argument(
        "--log-identifier",
        default="",
        help=argparse.SUPPRESS,  # Add given identifier to logged samples.
    )
    parser.add_argument(
        "--logger", help=argparse.SUPPRESS  # Specify custom logging binary.
    )
    parser.add_argument("--formatter", help=argparse.SUPPRESS)

    # Link tree determination.
    buck_arguments = parser.add_argument_group("buck")
    buck_arguments.add_argument(
        "--target", action="append", dest="targets", help="The buck target to check"
    )
    buck_arguments.add_argument(
        "--build",
        action="store_true",
        help="Freshly build all the necessary artifacts.",
    )
    buck_arguments.add_argument(
        "--use-buck-builder",
        action="store_true",
        help="Use Pyre's experimental builder for Buck projects.",
    )
    buck_arguments.add_argument(
        "--use-legacy-builder",
        action="store_true",
        help="Use Pyre's legacy builder for Buck projects.",
    )
    buck_arguments.add_argument(
        "--buck-builder-debug", action="store_true", help=argparse.SUPPRESS
    )

    source_directories = parser.add_argument_group("source-directories")
    source_directories.add_argument(
        "--source-directory",
        action="append",
        dest="source_directories",
        help="The source directory to check",
        type=os.path.abspath,
    )
    source_directories.add_argument(
        "--filter-directory", help=argparse.SUPPRESS  # override filter directory
    )

    parser.add_argument(
        "--use-global-shared-analysis-directory",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--no-saved-state",
        action="store_true",
        help="Don't attempt to load Pyre from a saved state.",
    )

    # Handling of search path
    parser.add_argument(
        "--search-path",
        action="append",
        default=[],
        type=readable_directory,
        help="Add an additional directory of modules and stubs to include"
        " in the type environment",
    )
    parser.add_argument(
        "--preserve-pythonpath",
        action="store_true",
        default=False,
        help="Preserve the value of the PYTHONPATH environment variable and "
        "inherit the current python environment's search path",
    )

    parser.add_argument(
        "--binary",
        default=None,
        type=executable_file,
        help="Location of the pyre binary",
    )

    parser.add_argument(
        "--buck-builder-binary",
        default=None,
        help="Location of the buck builder binary",
    )
    parser.add_argument("--buck-builder-target", default=None, help=argparse.SUPPRESS)

    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="Exclude files and directories matching this regexp from parsing",
    )

    # Typeshed stubs location
    parser.add_argument(
        "--typeshed",
        default=None,
        type=readable_directory,
        help="Location of the typeshed stubs",
    )
    parser.add_argument(
        "--save-initial-state-to",
        default=None,
        help="Path to serialize pyre's initial state to.",
    )
    parser.add_argument(
        "--load-initial-state-from", default=None, type=str, help=argparse.SUPPRESS
    )
    parser.add_argument(
        "--changed-files-path", default=None, type=str, help=argparse.SUPPRESS
    )
    parser.add_argument(
        "--saved-state-project", default=None, type=str, help=argparse.SUPPRESS
    )

    # Subcommands.
    parsed_commands = parser.add_subparsers(
        metavar="{analyze, check, color, kill, incremental, initialize (init), "
        "query, rage, restart, start, stop}",
        help="""
        The pyre command to run; defaults to `incremental`.
        Run `pyre command --help` for documentation on a specific command.
        """,
    )

    incremental_help = """
    Connects to a running Pyre server and returns the current type errors for your
    project. If no server exists for your projects, starts a new one. Running `pyre`
    implicitly runs `pyre incremental`.

    By default, incremental checks ensure that all dependencies of changed files are
    analyzed before returning results. If you'd like to get partial type checking
    results eagerly, you can run `pyre incremental --nonblocking`.
    """
    incremental = parsed_commands.add_parser(
        commands.Incremental.NAME, epilog=incremental_help
    )
    incremental.set_defaults(command=commands.Incremental)
    incremental.add_argument(
        "--nonblocking",
        action="store_true",
        help=(
            "Ask the server to return partial results immediately, "
            "even if analysis is still in progress."
        ),
    )
    incremental.add_argument(
        "--incremental-style",
        type=IncrementalStyle,
        choices=list(IncrementalStyle),
        default=IncrementalStyle.SHALLOW,
        help="How to approach doing incremental checks.",
    )
    rage = parsed_commands.add_parser(
        commands.Rage.NAME,
        epilog="""
        Collects troubleshooting diagnostics for Pyre, and writes this information to
        the terminal.
        """,
    )
    rage.set_defaults(command=commands.Rage)

    check = parsed_commands.add_parser(
        commands.Check.NAME,
        epilog="""
      Runs a one-time check of a project without initializing a type check server.
    """,
    )
    check.set_defaults(command=commands.Check)

    color = parsed_commands.add_parser(commands.Color.NAME)
    color.add_argument("path")
    color.set_defaults(command=commands.Color)

    deobfuscate = parsed_commands.add_parser(commands.Deobfuscate.NAME)

    deobfuscate.set_defaults(command=commands.Deobfuscate)

    analyze = parsed_commands.add_parser(commands.Analyze.NAME)
    analyze.set_defaults(command=commands.Analyze)
    analyze.add_argument(
        "analysis", nargs="?", default="taint", help="Type of analysis to run: {taint}"
    )
    analyze.add_argument(
        "--taint-models-path",
        action="append",
        default=[],
        type=readable_directory,
        help="Location of taint models",
    )
    analyze.add_argument(
        "--no-verify",
        action="store_true",
        help="Do not verify models for the taint analysis.",
    )
    analyze.add_argument(
        "--save-results-to",
        default=None,
        type=writable_directory,
        help="Directory to write analysis results to.",
    )
    analyze.add_argument("--dump-call-graph", action="store_true")

    persistent = parsed_commands.add_parser(
        commands.Persistent.NAME,
        epilog="""
        Entry point for IDE integration to Pyre. Communicates with a
        Pyre server using the Language Server Protocol, accepts input from stdin and
        writing diagnostics and responses from the Pyre server to stdout.
        """,
    )
    persistent.add_argument(
        "--no-watchman",
        action="store_true",
        help="Do not spawn a watchman client in the background.",
    )
    persistent.set_defaults(command=commands.Persistent, noninteractive=True)

    start = parsed_commands.add_parser(
        commands.Start.NAME, epilog="Starts a pyre server as a daemon."
    )
    start.add_argument(
        "--terminal", action="store_true", help="Run the server in the terminal."
    )
    start.add_argument(
        "--store-type-check-resolution",
        action="store_true",
        help="Store extra information for `types` queries.",
    )
    start.add_argument(
        "--no-watchman",
        action="store_true",
        help="Do not spawn a watchman client in the background.",
    )
    start.add_argument(
        "--incremental-style",
        type=IncrementalStyle,
        choices=list(IncrementalStyle),
        default=IncrementalStyle.SHALLOW,
        help="How to approach doing incremental checks.",
    )
    start.set_defaults(command=commands.Start)

    stop = parsed_commands.add_parser(
        commands.Stop.NAME, epilog="Signals the Pyre server to stop."
    )
    stop.set_defaults(command=commands.Stop)

    restart = parsed_commands.add_parser(
        commands.Restart.NAME,
        epilog="Restarts a server. Equivalent to `pyre stop && pyre start`.",
    )
    restart.add_argument(
        "--terminal", action="store_true", help="Run the server in the terminal."
    )
    restart.add_argument(
        "--store-type-check-resolution",
        action="store_true",
        help="Store extra information for `types` queries.",
    )
    restart.add_argument(
        "--no-watchman",
        action="store_true",
        help="Do not spawn a watchman client in the background.",
    )
    restart.add_argument(
        "--incremental-style",
        type=IncrementalStyle,
        choices=list(IncrementalStyle),
        default=IncrementalStyle.SHALLOW,
        help="How to approach doing incremental checks.",
    )
    restart.set_defaults(command=commands.Restart)

    kill = parsed_commands.add_parser(commands.Kill.NAME)
    kill.add_argument(
        "--with-fire", action="store_true", help="Adds emphasis to the command."
    )
    kill.set_defaults(command=commands.Kill)

    initialize = parsed_commands.add_parser(commands.Initialize.NAME, aliases=["init"])
    initialize.add_argument(
        "--local",
        action="store_true",
        help="Initializes a local configuration in a project subdirectory.",
    )
    initialize.set_defaults(command=commands.Initialize)

    query_message = """
    `https://pyre-check.org/docs/querying-pyre.html` contains examples and documentation
    for this command, which queries a running pyre server for type, function and
    attribute information.

    To get a full list of queries, you can run `pyre query help`.
    """
    query = parsed_commands.add_parser(commands.Query.NAME, epilog=query_message)
    query_argument_message = """
    `pyre query help` will give a full list of available queries for the running Pyre.
     Example: `pyre query "superclasses(int)"`.
    """
    query.add_argument("query", help=query_argument_message)
    query.set_defaults(command=commands.Query)

    infer = parsed_commands.add_parser(commands.Infer.NAME)
    infer.add_argument(
        "-p",
        "--print-only",
        action="store_true",
        help="Print raw JSON errors to standard output, "
        + "without converting to stubs or annnotating.",
    )
    infer.add_argument(
        "-f",
        "--full-only",
        action="store_true",
        help="Only output fully annotated functions. Requires infer flag.",
    )
    infer.add_argument(
        "-r",
        "--recursive",
        action="store_true",
        help="Recursively run infer until no new annotations are generated."
        + " Requires infer flag.",
    )
    infer.add_argument(
        "-i",
        "--in-place",
        nargs="*",
        metavar="path",
        type=file_exists,
        help="Add annotations to functions in selected paths."
        + " Takes a set of files and folders to add annotations to."
        + " If no paths are given, all functions are annotated."
        + " WARNING: Modifies original files and requires infer flag and retype",
    )
    infer.add_argument(
        "--json",
        action="store_true",
        help="Accept JSON input instead of running full check.",
    )
    infer.add_argument(
        "--annotate-from-existing-stubs",
        action="store_true",
        help="Add annotations from existing stubs.",
    )
    infer.add_argument(
        "--debug-infer",
        action="store_true",
        help="Print error message when file fails to annotate.",
    )
    infer.set_defaults(command=commands.Infer)

    statistics = parsed_commands.add_parser(commands.Statistics.NAME)
    statistics.add_argument(
        "filter_paths",
        nargs="*",
        type=file_exists,
        help="Source path(s) to gather metrics for.",
    )
    statistics.set_defaults(command=commands.Statistics)

    profile = parsed_commands.add_parser(commands.Profile.NAME)
    profile.add_argument(
        "--output",
        type=ProfileOutput,
        choices=ProfileOutput,
        help="Specify what to output.",
        default=ProfileOutput.COLD_START_PHASES,
    )
    profile.set_defaults(command=commands.Profile)

    arguments = parser.parse_args()

    if not hasattr(arguments, "command"):
        if shutil.which("watchman"):
            # pyre-fixme[16]: `Namespace` has no attribute `command`.
            arguments.command = commands.Incremental
            # pyre-fixme[16]: `Namespace` has no attribute `nonblocking`.
            arguments.nonblocking = False
            # pyre-fixme[16]: `Namespace` has no attribute `transitive`.
            arguments.incremental_style = IncrementalStyle.SHALLOW
        else:
            watchman_link = "https://facebook.github.io/watchman/docs/install.html"
            LOG.warning(
                "No watchman binary found. \n"
                "To enable pyre incremental, "
                "you can install watchman: {}".format(watchman_link)
            )
            LOG.warning("Defaulting to non-incremental check.")
            arguments.command = commands.Check

    configuration = None
    analysis_directory = None
    # Having this as a fails-by-default helps flag unexpected exit
    # from exception flows.
    exit_code = ExitCode.FAILURE
    start = time.time()
    try:
        # pyre-fixme[16]: `Namespace` has no attribute `capable_terminal`.
        arguments.capable_terminal = is_capable_terminal()
        if arguments.debug or not arguments.capable_terminal:
            # pyre-fixme[16]: `Namespace` has no attribute `noninteractive`.
            arguments.noninteractive = True

        switch_root(arguments)
        translate_arguments(commands, arguments)
        find_log_directory(arguments)
        log.initialize(arguments)

        if arguments.command in [commands.Initialize]:
            analysis_directory = AnalysisDirectory(".")
        else:
            if arguments.version:
                binary_version = get_binary_version_from_file(
                    arguments.local_configuration
                )
                log.stdout.write(
                    "binary version: {}\nclient version: {}".format(
                        binary_version, __version__
                    )
                )
                return ExitCode.SUCCESS
            configuration = Configuration(
                local_configuration=arguments.local_configuration,
                search_path=arguments.search_path,
                binary=arguments.binary,
                typeshed=arguments.typeshed,
                preserve_pythonpath=arguments.preserve_pythonpath,
                excludes=arguments.exclude,
                logger=arguments.logger,
                formatter=arguments.formatter,
                log_directory=arguments.log_directory,
            )
            if configuration.disabled:
                LOG.log(
                    log.SUCCESS, "Pyre will not run due to being explicitly disabled"
                )
                return ExitCode.SUCCESS

            if arguments.command in [commands.Kill]:
                analysis_directory = AnalysisDirectory(".")
            else:
                isolate = (
                    arguments.command in [commands.Analyze, commands.Check]
                    and not arguments.use_global_shared_analysis_directory
                )
                analysis_directory = resolve_analysis_directory(
                    arguments, commands, configuration, isolate=isolate
                )

        command = arguments.command
        exit_code = (
            command(arguments, configuration, analysis_directory).run().exit_code()
        )
    except buck.BuckException as error:
        LOG.error(str(error))
        if arguments.command == commands.Persistent:
            commands.Persistent.run_null_server(timeout=3600 * 12)
        exit_code = ExitCode.BUCK_ERROR
    except EnvironmentException as error:
        LOG.error(str(error))
        if arguments.command == commands.Persistent:
            commands.Persistent.run_null_server(timeout=3600 * 12)
        exit_code = ExitCode.FAILURE
    except commands.ClientException as error:
        LOG.error(str(error))
        exit_code = ExitCode.FAILURE
    except Exception as error:
        LOG.error(str(error))
        LOG.info(traceback.format_exc())
        exit_code = ExitCode.FAILURE
    except KeyboardInterrupt:
        LOG.warning("Interrupted by user")
        LOG.debug(traceback.format_exc())
        exit_code = ExitCode.SUCCESS
    finally:
        log.cleanup(arguments)
        if analysis_directory:
            analysis_directory.cleanup()
        if configuration and configuration.logger:
            log_statistics(
                "perfpipe_pyre_usage",
                arguments=arguments,
                configuration=configuration,
                integers={
                    "exit_code": exit_code,
                    "runtime": int((time.time() - start) * 1000),
                },
                normals={"cwd": os.getcwd(), "client_version": __version__},
            )

    return exit_code


if __name__ == "__main__":
    try:
        os.getcwd()
    except FileNotFoundError:
        LOG.error(
            "Pyre could not determine the current working directory. "
            "Has it been removed?\nExiting."
        )
        sys.exit(ExitCode.FAILURE)
    sys.exit(main())
