(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core

let base_command_line_arguments =
  Command.Spec.(
    empty
    +> flag "-verbose" no_arg ~doc:"Turn on verbose logging"
    +> flag
         "-expected-binary-version"
         (optional string)
         ~doc:
           "VERSION When connecting to a server, this is version we are expecting to connect to."
    +> flag
         "-logging-sections"
         (optional_with_default [] (Arg_type.comma_separated string))
         ~doc:
           "SECTION1,... Comma-separated list of logging sections. Prefix a section name with a \
            dash to disable it."
    +> flag "-debug" no_arg ~doc:"Turn on debug mode"
    +> flag "-strict" no_arg ~doc:"Turn on strict mode"
    +> flag "-show-error-traces" no_arg ~doc:"Outputs additional error information"
    +> flag "-infer" no_arg ~doc:"Outputs extra information and errors for inference purposes"
    +> flag
         "-additional-checks"
         (optional_with_default [] (Arg_type.comma_separated string))
         ~doc:"Run additional checks after type checking"
    +> flag "-sequential" no_arg ~doc:"Turn off parallel processing (parallel on by default)."
    +> flag
         "-filter-directories"
         (optional string)
         ~doc:
           "DIRECTORY1;... Only report errors for files under one of the semicolon-separated \
            filter directories."
    +> flag
         "-ignore-all-errors"
         (optional string)
         ~doc:
           "DIRECTORY1;... Ignore all errors originating from under one of the \
            semicolon-separated directories."
    +> flag
         "-workers"
         (optional_with_default 4 int)
         ~doc:"WORKERS Number of workers to use in parallel processing."
    +> flag
         "-log-identifier"
         (optional_with_default "" string)
         ~doc:"IDENTIFIER Add given identifier to logged samples."
    +> flag "-logger" (optional string) ~doc:"Tool used for logging statistics."
    +> flag
         "-profiling-output"
         (optional string)
         ~doc:"FILE If provided, write profiling output to this file."
    +> flag
         "-project-root"
         (optional_with_default "/" string)
         ~doc:"ROOT Only check sources under this root directory."
    +> flag
         "-search-path"
         (optional_with_default [] (Arg_type.comma_separated string))
         ~doc:"DIRECTORY1,... Directories containing external modules to include."
    +> flag
         "-taint-models"
         (listed string)
         ~doc:"DIRECTORY containing models for the taint analysis."
    +> flag
         "-exclude"
         (listed string)
         ~doc:"REGEXP Do not parse relative paths (files and directories) matching this regexp."
    +> flag
         "-extension"
         (listed string)
         ~doc:".EXT Consider the given extension as equivalent to `.py` for type checking."
    +> anon (maybe_with_default "." ("source-root" %: string)))
