# flake8: noqa
from typing import Any, Dict


def dictionary_source():
    result = {"a": __test_source()}
    return result


def dictionary_entry_sink(arg):
    result = {"a": __test_sink(arg)}


def dictionary_tito(arg):
    result = {"a": arg}
    return result


def dictionary_assignment_source():
    d = {}
    d["a"] = __test_source()
    return d["a"]


def dictionary_non_source():
    d = {}
    d["a"] = __test_source()
    return d["b"]


def dictionary_assign_to_index():
    d = {}
    d["a"] = __test_source()
    return d


def dictionary_nested_assignment_1():
    d = {}
    d["a"]["b"] = __test_source()
    return d["a"]["b"]


def dictionary_nested_assignment_2():
    d = {}
    d["a"]["b"] = __test_source()
    return d["a"]


def dictionary_nested_non_source_assignment():
    d = {}
    d["a"]["b"] = __test_source()
    return d["a"]["a"]


tainted_dictionary: Dict[Any, Any] = {}


def update_tainted_dictionary():
    tainted_dictionary.update({"a": __test_source()})


def update_dictionary_indirectly(arg):
    tainted_dictionary.update(arg)


def indirect_flow_from_source_to_global_dictionary():
    update_dictionary_indirectly({"a": __test_source()})


def update_parameter(arg):
    arg.update({"a": __test_source})


def flow_through_keywords():
    tainted_map = {"a": __test_source()}
    new_map = {**tainted_map}
    __test_sink(tainted_map["a"])


class SpecialSetitemDict(Dict[Any, Any]):
    def __setitem__(self, key: Any, value: Any) -> None:
        __test_sink(key)


def tainted_setitem(d: SpecialSetitemDict) -> SpecialSetitemDict:
    d[__test_source()] = 1
    return d


def forward_comprehension_value_source():
    d = {"a": __test_source() for x in []}
    return d


def forward_comprehension_key_source():
    d = {__test_source(): 0 for x in []}
    return d


def forward_comprehension_value_sink(arg):
    d = {"a": __test_sink(x) for x in [arg]}


def forward_comprehension_key_sink(arg):
    d = {__test_sink(x): 0 for x in [arg]}
