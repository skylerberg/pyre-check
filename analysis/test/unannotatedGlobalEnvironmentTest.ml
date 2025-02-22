(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2
open Ast
open Analysis
open Pyre
open Test

let test_simple_registration context =
  let assert_registers ?(expected = true) source name =
    let project = ScratchProject.setup ["test.py", source] ~context in
    let ast_environment, ast_environment_update_result = ScratchProject.parse_sources project in
    let unannotated_global_environment =
      UnannotatedGlobalEnvironment.create (AstEnvironment.read_only ast_environment)
    in
    let _ =
      UnannotatedGlobalEnvironment.update
        unannotated_global_environment
        ~scheduler:(mock_scheduler ())
        ~configuration:(Configuration.Analysis.create ())
        ~ast_environment_update_result
        (Reference.Set.singleton (Reference.create "test"))
    in
    let read_only = UnannotatedGlobalEnvironment.read_only unannotated_global_environment in
    assert_equal (UnannotatedGlobalEnvironment.ReadOnly.class_exists read_only name) expected
  in
  assert_registers {|
   class Bar:
     pass
  |} "test.Bar";
  assert_registers ~expected:false {|
   class Foo:
     pass
  |} "test.Bar";
  ()


let test_simple_global_registration context =
  let assert_registers source name expected =
    let project = ScratchProject.setup ["test.py", source] ~context in
    let ast_environment, ast_environment_update_result = ScratchProject.parse_sources project in
    let unannotated_global_environment =
      UnannotatedGlobalEnvironment.create (AstEnvironment.read_only ast_environment)
    in
    let _ =
      UnannotatedGlobalEnvironment.update
        unannotated_global_environment
        ~scheduler:(mock_scheduler ())
        ~configuration:(Configuration.Analysis.create ())
        ~ast_environment_update_result
        (Reference.Set.singleton (Reference.create "test"))
    in
    let read_only = UnannotatedGlobalEnvironment.read_only unannotated_global_environment in
    let printer global =
      global
      >>| UnannotatedGlobalEnvironment.show_unannotated_global
      |> Option.value ~default:"None"
    in
    let location_insensitive_compare left right =
      Option.compare UnannotatedGlobalEnvironment.compare_unannotated_global left right = 0
    in
    assert_equal
      ~cmp:location_insensitive_compare
      ~printer
      (UnannotatedGlobalEnvironment.ReadOnly.get_unannotated_global
         read_only
         (Reference.create name))
      expected
  in
  let target_location =
    {
      Location.path = Reference.create "test";
      start = { line = 2; column = 0 };
      stop = { line = 2; column = 3 };
    }
  in
  let value_location =
    {
      Location.path = Reference.create "test";
      start = { line = 2; column = 6 };
      stop = { line = 2; column = 7 };
    }
  in
  let value =
    let value = parse_single_expression "8" in
    { value with location = value_location }
  in
  assert_registers
    {|
    bar = 8
  |}
    "test.bar"
    (Some (SimpleAssign { explicit_annotation = None; value; target_location }));
  assert_registers {|
    other.bar = 8
  |} "test.other.bar" None;
  assert_registers {|
    other.bar = 8
  |} "other.bar" None;
  let parse_define define =
    match parse_single_statement define ~preprocess:true ~handle:"test.py" with
    | { Node.value = Statement.Statement.Define { signature; _ }; location } ->
        Node.create signature ~location
    | _ -> failwith "not define"
  in
  assert_registers
    {|
      def foo(x: int) -> str:
        pass
      def foo(x: float) -> bool:
        pass
    |}
    "test.foo"
    (Some
       (Define
          [
            parse_define
              {|
                def foo(x: int) -> str:
                    pass
              |};
            parse_define
              {|
                def foo(x: float) -> bool:
                  pass
              |};
          ]));
  ()


let test_updates context =
  let assert_updates
      ?original_source
      ?new_source
      ~middle_actions
      ~expected_triggers
      ?post_actions
      ()
    =
    Memory.reset_shared_memory ();
    let sources = original_source >>| (fun source -> "test.py", source) |> Option.to_list in
    let project =
      ScratchProject.setup
        ~include_typeshed_stubs:false
        ~incremental_style:FineGrained
        sources
        ~context
    in
    let ast_environment, ast_environment_update_result = ScratchProject.parse_sources project in
    let unannotated_global_environment =
      UnannotatedGlobalEnvironment.create (AstEnvironment.read_only ast_environment)
    in
    let configuration = ScratchProject.configuration_of project in
    let _ =
      UnannotatedGlobalEnvironment.update
        unannotated_global_environment
        ~scheduler:(mock_scheduler ())
        ~configuration
        ~ast_environment_update_result
        (Reference.Set.singleton (Reference.create "test"))
    in
    let read_only = UnannotatedGlobalEnvironment.read_only unannotated_global_environment in
    let execute_action = function
      | `Get (class_name, dependency, expected_number_of_statements) ->
          let printer number =
            number
            >>| Format.sprintf "number of attributes: %d"
            |> Option.value ~default:"No class"
          in
          UnannotatedGlobalEnvironment.ReadOnly.get_class_definition
            read_only
            ~dependency
            class_name
          >>| Node.value
          >>| (fun { ClassSummary.attribute_components; _ } -> attribute_components)
          >>| Ast.Statement.Class.attributes
          >>| Identifier.SerializableMap.bindings
          >>| List.length
          |> assert_equal ~printer expected_number_of_statements
      | `Mem (class_name, dependency, expectation) ->
          UnannotatedGlobalEnvironment.ReadOnly.class_exists read_only ~dependency class_name
          |> assert_equal expectation
      | `AllClasses expectation ->
          UnannotatedGlobalEnvironment.ReadOnly.all_classes read_only
          |> assert_equal ~printer:(List.to_string ~f:Fn.id) expectation
      | `Global (global_name, dependency, expectation) ->
          let printer optional =
            optional
            >>| UnannotatedGlobalEnvironment.show_unannotated_global
            |> Option.value ~default:"none"
          in
          let cmp left right =
            Option.compare UnannotatedGlobalEnvironment.compare_unannotated_global left right = 0
          in
          let remove_target_location = function
            | UnannotatedGlobalEnvironment.SimpleAssign assign ->
                UnannotatedGlobalEnvironment.SimpleAssign
                  { assign with target_location = Location.Reference.any }
            | UnannotatedGlobalEnvironment.TupleAssign assign ->
                UnannotatedGlobalEnvironment.TupleAssign
                  { assign with target_location = Location.Reference.any }
            | global -> global
          in
          UnannotatedGlobalEnvironment.ReadOnly.get_unannotated_global
            read_only
            global_name
            ~dependency
          >>| remove_target_location
          |> assert_equal ~cmp ~printer expectation
    in
    List.iter middle_actions ~f:execute_action;
    let add_file
        { ScratchProject.configuration = { Configuration.Analysis.local_root; _ }; _ }
        content
        ~relative
      =
      let content = trim_extra_indentation content in
      let file = File.create ~content (Path.create_relative ~root:local_root ~relative) in
      File.write file
    in
    let delete_file
        { ScratchProject.configuration = { Configuration.Analysis.local_root; _ }; _ }
        relative
      =
      Path.create_relative ~root:local_root ~relative |> Path.absolute |> Core.Unix.remove
    in
    if Option.is_some original_source then
      delete_file project "test.py";
    new_source >>| add_file project ~relative:"test.py" |> Option.value ~default:();
    let { ScratchProject.module_tracker; _ } = project in
    let { Configuration.Analysis.local_root; _ } = configuration in
    let path = Path.create_relative ~root:local_root ~relative:"test.py" in
    let update_result =
      ModuleTracker.update ~configuration ~paths:[path] module_tracker
      |> (fun updates -> AstEnvironment.Update updates)
      |> AstEnvironment.update ~configuration ~scheduler:(mock_scheduler ()) ast_environment
      |> fun ast_environment_update_result ->
      UnannotatedGlobalEnvironment.update
        unannotated_global_environment
        ~scheduler:(mock_scheduler ())
        ~configuration
        ~ast_environment_update_result
        (Reference.Set.singleton (Reference.create "test"))
    in
    let printer set =
      SharedMemoryKeys.DependencyKey.KeySet.elements set
      |> List.to_string ~f:SharedMemoryKeys.show_dependency
    in
    let expected_triggers = SharedMemoryKeys.DependencyKey.KeySet.of_list expected_triggers in
    assert_equal
      ~printer
      expected_triggers
      (UnannotatedGlobalEnvironment.UpdateResult.locally_triggered_dependencies update_result);
    post_actions >>| List.iter ~f:execute_action |> Option.value ~default:()
  in
  let dependency = SharedMemoryKeys.TypeCheckSource (Reference.create "dep") in
  (* get_class_definition *)
  assert_updates
    ~original_source:{|
      class Foo:
        x: int
    |}
    ~new_source:{|
      class Foo:
        x: str
    |}
    ~middle_actions:[`Get ("test.Foo", dependency, Some 1)]
    ~expected_triggers:[dependency]
    ();
  assert_updates
    ~original_source:{|
      class Foo:
        x: int
    |}
    ~new_source:{|
      class Foo:
        x: str
    |}
    ~middle_actions:[`Get ("test.Missing", dependency, None)]
    ~expected_triggers:[]
    ();
  assert_updates
    ~original_source:{|
      class Foo:
        x: int
    |}
    ~new_source:{|
      class Unrelated:
        x: int
      class Foo:
        x: int
    |}
    ~middle_actions:[`Get ("test.Foo", dependency, Some 1)]
    ~expected_triggers:[]
    ();

  (* First class definition wins *)
  assert_updates
    ~original_source:
      {|
      class Foo:
        x: int
      class Foo:
        x: int
        y: int
    |}
    ~new_source:{|
      class Unrelated:
        x: int
      class Foo:
        x: int
    |}
    ~middle_actions:[`Get ("test.Foo", dependency, Some 1)]
    ~expected_triggers:[]
    ();

  (* class_exists *)
  assert_updates
    ~new_source:{|
      class Foo:
        x: int
    |}
    ~middle_actions:[`Mem ("test.Foo", dependency, false)]
    ~expected_triggers:[dependency]
    ();
  assert_updates
    ~original_source:{|
      class Foo:
        x: int
    |}
    ~middle_actions:[`Mem ("test.Foo", dependency, true)]
    ~expected_triggers:[dependency]
    ();
  assert_updates
    ~original_source:{|
      class Foo:
        x: int
    |}
    ~new_source:{|
      class Foo:
        x: int
    |}
    ~middle_actions:[`Mem ("test.Foo", dependency, true)]
    ~expected_triggers:[]
    ();

  (* TODO(T53500184): need to add an existence-only dependency "kind" *)
  assert_updates
    ~original_source:{|
      class Foo:
        x: int
    |}
    ~new_source:{|
      class Foo:
        x: str
    |}
    ~middle_actions:[`Mem ("test.Foo", dependency, true)]
    ~expected_triggers:[dependency]
    ();

  (* all_classes *)
  assert_updates
    ~original_source:{|
      class Foo:
        x: int
      class Bar:
        y: str
    |}
    ~new_source:{|
      class Foo:
        x: str
    |}
    ~middle_actions:[`AllClasses ["test.Bar"; "test.Foo"]]
    ~expected_triggers:[]
    ~post_actions:[`AllClasses ["test.Foo"]]
    ();

  (* get_unannotated_global *)
  let dependency = SharedMemoryKeys.AliasRegister (Reference.create "dep") in
  assert_updates
    ~original_source:{|
      x: int = 7
    |}
    ~new_source:{|
      x: int = 9
    |}
    ~middle_actions:
      [
        `Global
          ( Reference.create "test.x",
            dependency,
            Some
              (UnannotatedGlobalEnvironment.SimpleAssign
                 {
                   explicit_annotation = Some (parse_single_expression "int");
                   value = parse_single_expression "7";
                   target_location = Location.Reference.any;
                 }) );
      ]
    ~expected_triggers:[dependency]
    ~post_actions:
      [
        `Global
          ( Reference.create "test.x",
            dependency,
            Some
              (UnannotatedGlobalEnvironment.SimpleAssign
                 {
                   explicit_annotation = Some (parse_single_expression "int");
                   value = parse_single_expression "9";
                   target_location = Location.Reference.any;
                 }) );
      ]
    ();
  assert_updates
    ~original_source:{|
      import target.member as alias
    |}
    ~new_source:{|
      import target.member as new_alias
    |}
    ~middle_actions:
      [
        `Global
          ( Reference.create "test.alias",
            dependency,
            Some (UnannotatedGlobalEnvironment.Imported (Reference.create "target.member")) );
      ]
    ~expected_triggers:[dependency]
    ~post_actions:[`Global (Reference.create "test.alias", dependency, None)]
    ();
  assert_updates
    ~original_source:{|
      from target import member, other_member
    |}
    ~new_source:{|
      from target import other_member, member
    |}
    ~middle_actions:
      [
        `Global
          ( Reference.create "test.member",
            dependency,
            Some (UnannotatedGlobalEnvironment.Imported (Reference.create "target.member")) );
        `Global
          ( Reference.create "test.other_member",
            dependency,
            Some (UnannotatedGlobalEnvironment.Imported (Reference.create "target.other_member"))
          );
      ]
      (* Location insensitive *)
    ~expected_triggers:[]
    ~post_actions:
      [
        `Global
          ( Reference.create "test.member",
            dependency,
            Some (UnannotatedGlobalEnvironment.Imported (Reference.create "target.member")) );
        `Global
          ( Reference.create "test.other_member",
            dependency,
            Some (UnannotatedGlobalEnvironment.Imported (Reference.create "target.other_member"))
          );
      ]
    ();

  (* Don't infer * as a real thing *)
  assert_updates
    ~original_source:{|
      from target import *
    |}
    ~middle_actions:[`Global (Reference.create "test.*", dependency, None)]
    ~expected_triggers:[]
    ();

  assert_updates
    ~original_source:{|
      X, Y, Z = int, str, bool
    |}
    ~middle_actions:
      [
        `Global
          ( Reference.create "test.X",
            dependency,
            Some
              (UnannotatedGlobalEnvironment.TupleAssign
                 {
                   value = parse_single_expression "int, str, bool";
                   index = 0;
                   target_location = Location.Reference.any;
                   total_length = 3;
                 }) );
        `Global
          ( Reference.create "test.Y",
            dependency,
            Some
              (UnannotatedGlobalEnvironment.TupleAssign
                 {
                   value = parse_single_expression "int, str, bool";
                   index = 1;
                   target_location = Location.Reference.any;
                   total_length = 3;
                 }) );
        `Global
          ( Reference.create "test.Z",
            dependency,
            Some
              (UnannotatedGlobalEnvironment.TupleAssign
                 {
                   value = parse_single_expression "int, str, bool";
                   index = 2;
                   target_location = Location.Reference.any;
                   total_length = 3;
                 }) );
      ]
    ~expected_triggers:[dependency]
    ();

  (* First global wins. Kind of weird behavior, but that's the current approach so sticking with it
     for now *)
  assert_updates
    ~original_source:{|
      X = int
      X = str
    |}
    ~new_source:{|
      X = int
      X = str
    |}
    ~middle_actions:
      [
        `Global
          ( Reference.create "test.X",
            dependency,
            Some
              (UnannotatedGlobalEnvironment.SimpleAssign
                 {
                   explicit_annotation = None;
                   value = parse_single_expression "int";
                   target_location = Location.Reference.any;
                 }) );
      ]
    ~expected_triggers:[]
    ();

  (* Only recurse into ifs *)
  assert_updates
    ~original_source:{|
      if condition:
        X = int
      else:
        X = str
    |}
    ~new_source:{|
      if condition:
        X = int
      else:
        X = str
    |}
    ~middle_actions:
      [
        `Global
          ( Reference.create "test.X",
            dependency,
            Some
              (UnannotatedGlobalEnvironment.SimpleAssign
                 {
                   explicit_annotation = None;
                   value = parse_single_expression "int";
                   target_location = Location.Reference.any;
                 }) );
      ]
    ~expected_triggers:[]
    ();

  (* Keep different dependencies straight *)
  let alias_dependency = SharedMemoryKeys.AliasRegister (Reference.create "same_dep") in
  let check_dependency = SharedMemoryKeys.TypeCheckSource (Reference.create "same_dep") in
  assert_updates
    ~original_source:{|
      class Foo:
        x: int
    |}
    ~new_source:{|
      class Foo:
        x: str
    |}
    ~middle_actions:
      [`Get ("test.Foo", alias_dependency, Some 1); `Get ("test.Foo", check_dependency, Some 1)]
    ~expected_triggers:[alias_dependency; check_dependency]
    ();

  (* Addition should trigger previous failed reads *)
  assert_updates
    ~original_source:{|
    |}
    ~new_source:{|
      x: int = 9
    |}
    ~middle_actions:[`Global (Reference.create "test.x", dependency, None)]
    ~expected_triggers:[dependency]
    ~post_actions:
      [
        `Global
          ( Reference.create "test.x",
            dependency,
            Some
              (UnannotatedGlobalEnvironment.SimpleAssign
                 {
                   explicit_annotation = Some (parse_single_expression "int");
                   value = parse_single_expression "9";
                   target_location = Location.Reference.any;
                 }) );
      ]
    ();
  assert_updates
    ~original_source:
      {|
      class Foo:
        def method(self) -> None:
         print("hello")
    |}
    ~new_source:{|
      class Foo:
        def method(self) -> int:
          return 1
    |}
    ~middle_actions:[`Get ("test.Foo", dependency, Some 1)]
    ~expected_triggers:[dependency]
    ~post_actions:[`Get ("test.Foo", dependency, Some 1)]
    ();
  assert_updates
    ~original_source:
      {|
      class Foo:
        def method(self) -> None:
         print("hello")
    |}
    ~new_source:
      {|
      class Foo:
        def method(self) -> None:
         print("goodbye")
    |}
    ~middle_actions:[`Get ("test.Foo", dependency, Some 1)]
    ~expected_triggers:[]
    ~post_actions:[`Get ("test.Foo", dependency, Some 1)]
    ();
  let parse_define define =
    match parse_single_statement define ~preprocess:true ~handle:"test.py" with
    | { Node.value = Statement.Statement.Define { signature; _ }; location } ->
        Node.create signature ~location
    | _ -> failwith "not define"
  in
  assert_updates
    ~original_source:{|
      def foo() -> None:
       print("hello")
    |}
    ~new_source:{|
      def foo() -> None:
       print("goodbye")
    |}
    ~middle_actions:
      [
        `Global
          ( Reference.create "test.foo",
            dependency,
            Some (UnannotatedGlobalEnvironment.Define [parse_define "def foo() -> None: pass"]) );
      ]
    ~expected_triggers:[]
    ~post_actions:
      [
        `Global
          ( Reference.create "test.foo",
            dependency,
            Some (UnannotatedGlobalEnvironment.Define [parse_define "def foo() -> None: pass"]) );
      ]
    ();
  ()


let () =
  "environment"
  >::: [
         "simple_registration" >:: test_simple_registration;
         "simple_globals" >:: test_simple_global_registration;
         "updates" >:: test_updates;
       ]
  |> Test.run
