# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-unsafe

import argparse
import ast
import logging
import pathlib
from typing import Callable

from pyre_extensions import ListVariadic


Ts = ListVariadic("Ts")


LOG = logging.getLogger(__name__)


def verify_stable_ast(file_modifier: Callable[[Ts], None]) -> Callable[[Ts], None]:
    def wrapper(arguments: argparse.Namespace, filename: str, *args):
        # AST before changes
        path = pathlib.Path(filename)
        try:
            text = path.read_text()
            ast_before = ast.parse(text)

            # AST after changes
            file_modifier(arguments, filename, *args)
            new_text = path.read_text()
            try:
                ast_after = ast.parse(new_text)
            except Exception as e:
                LOG.warning("Could not parse file %s. Undoing.", filename)
                LOG.warning(e)
                path.write_text(text)

            # Undo changes if AST does not match
            if not ast.dump(ast_before) == ast.dump(ast_after):
                LOG.warning(
                    "Attempted file changes modified the AST in %s. Undoing.", filename
                )
                path.write_text(text)
        except FileNotFoundError:
            LOG.warning("File %s cannot be found, skipping.", filename)
            return

    return wrapper
