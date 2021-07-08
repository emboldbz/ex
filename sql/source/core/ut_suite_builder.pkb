create or replace package body ut_suite_builder is
  /*
  utPLSQL - Version 3
  Copyright 2016 - 2018 utPLSQL Project

  Licensed under the Apache License, Version 2.0 (the "License"):
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
  */

  subtype t_annotation_text     is varchar2(4000);
  subtype t_annotation_name     is varchar2(4000);
  subtype t_object_name         is varchar2(500);
  subtype t_annotation_position is binary_integer;

  gc_suite                       constant t_annotation_name := 'suite';
  gc_suitepath                   constant t_annotation_name := 'suitepath';
  gc_test                        constant t_annotation_name := ut_utils.gc_test_execute;
  gc_disabled                    constant t_annotation_name := 'disabled';
  gc_displayname                 constant t_annotation_name := 'displayname';
  gc_beforeall                   constant t_annotation_name := ut_utils.gc_before_all;
  gc_beforeeach                  constant t_annotation_name := ut_utils.gc_before_each;
  gc_beforetest                  constant t_annotation_name := ut_utils.gc_before_test;
  gc_afterall                    constant t_annotation_name := ut_utils.gc_after_all;
  gc_aftereach                   constant t_annotation_name := ut_utils.gc_after_each;
  gc_aftertest                   constant t_annotation_name := ut_utils.gc_after_test;
  gc_throws                      constant t_annotation_name := 'throws';
  gc_rollback                    constant t_annotation_name := 'rollback';
  gc_context                     constant t_annotation_name := 'context';
  gc_endcontext                  constant t_annotation_name := 'endcontext';

  type tt_annotations is table of t_annotation_name;

  gc_supported_annotations       constant tt_annotations
    := tt_annotations(
      gc_suite,
      gc_suitepath,
      gc_test,
      gc_disabled,
      gc_displayname,
      gc_beforeall,
      gc_beforeeach,
      gc_beforetest,
      gc_afterall,
      gc_aftereach,
      gc_aftertest,
      gc_throws,
      gc_rollback,
      gc_context,
      gc_endcontext
  );

  gc_placeholder                 constant varchar2(3) := '\\%';
  
  gc_integer_exception           constant varchar2(1) := 'I';
  gc_named_exception             constant varchar2(1) := 'N';

  type tt_executables is table of ut_executables index by t_annotation_position;

  type tt_tests is table of ut_test index by t_annotation_position;


  type t_annotation is record(
    name                  t_annotation_name,
    text                  t_annotation_text,
    procedure_name        t_object_name
  );
  
  type tt_annotations_by_line is table of t_annotation index by t_annotation_position;

  --list of annotation texts for a given annotation indexed by annotation position:
  --This would hold: ('some', 'other') for a single annotation name recurring in a single procedure example
  --  --%beforetest(some)
  --  --%beforetest(other)
  --  --%test(some test with two before test procedures)
  --  procedure some_test ...
  -- when you'd like to have two beforetest procedures executed in a single test
  type tt_annotation_texts is table of t_annotation_text index by t_annotation_position;
  
  type tt_annotations_by_name is table of tt_annotation_texts index by t_annotation_name;

  type tt_annotations_by_proc is table of tt_annotations_by_name index by t_object_name;

  type t_annotations_info is record (
    owner   t_object_name,
    name    t_object_name,
    by_line tt_annotations_by_line,
    by_proc tt_annotations_by_proc,
    by_name tt_annotations_by_name
  );

  procedure delete_annotations_range(
    a_annotations in out nocopy t_annotations_info,
    a_start_pos   t_annotation_position,
    a_end_pos     t_annotation_position
  ) is
    l_pos         t_annotation_position := a_start_pos;
    l_annotation  t_annotation;
  begin
    while l_pos is not null and l_pos <= a_end_pos loop
      l_annotation := a_annotations.by_line(l_pos);
      if l_annotation.procedure_name is not null and a_annotations.by_proc.exists(l_annotation.procedure_name) then
        a_annotations.by_proc.delete(l_annotation.procedure_name);
      elsif a_annotations.by_name.exists(l_annotation.name) then
        a_annotations.by_name(l_annotation.name).delete(l_pos);
        if a_annotations.by_name(l_annotation.name).count = 0 then
          a_annotations.by_name.delete(l_annotation.name);
        end if;
      end if;
      l_pos := a_annotations.by_line.next( l_pos );
    end loop;
    a_annotations.by_line.delete(a_start_pos, a_end_pos);
  end;

  -----------------------------------------------
  -- Processing annotations
  -----------------------------------------------

  function get_qualified_object_name(
    a_suite ut_suite_item, a_procedure_name t_object_name
  ) return varchar2 is
    l_result varchar2(1000);
  begin
    if a_suite is not null then
      l_result := upper( a_suite.object_owner || '.' || a_suite.object_name );
      if a_procedure_name is not null then
        l_result := l_result || upper( '.' || a_procedure_name );
      end if;
    end if;
    return l_result;
  end;

  procedure add_annotation_ignored_warning(
    a_suite          in out nocopy ut_suite_item,
    a_annotation     t_annotation_name,
    a_message        varchar2,
    a_line_no        binary_integer,
    a_procedure_name t_object_name := null
  ) is
  begin
    a_suite.put_warning(
        replace(a_message,'%%%','"--%'||a_annotation||'"') || ' Annotation ignored.'
        || chr( 10 ) || 'at "' || get_qualified_object_name(a_suite, a_procedure_name) || '", line ' || a_line_no
    );
  end;

  function get_rollback_type(a_rollback_type_name varchar2) return ut_utils.t_rollback_type is
    l_rollback_type ut_utils.t_rollback_type;
  begin
    l_rollback_type :=
      case lower(a_rollback_type_name)
        when 'manual' then ut_utils.gc_rollback_manual
        when 'auto' then ut_utils.gc_rollback_auto
      end;
     return l_rollback_type;
  end;

  procedure add_to_throws_numbers_list(
    a_suite           in out nocopy ut_suite,
    a_list            in out nocopy ut_integer_list,
    a_procedure_name  t_object_name,
    a_throws_ann_text tt_annotation_texts
  ) is
    l_annotation_pos binary_integer;

    function is_valid_qualified_name (a_name varchar2) return boolean is
      l_name varchar2(500);
    begin
      l_name := dbms_assert.qualified_sql_name(a_name);
      return true;
      exception when others then
      return false;
    end;

    function check_exception_type(a_exception_name in varchar2) return varchar2 is
      l_exception_type varchar2(50);
    begin
      --check if it is a predefined exception
      begin
        execute immediate 'begin null; exception when '||a_exception_name||' then null; end;';
        l_exception_type := gc_named_exception;
        exception
        when others then
        if dbms_utility.format_error_stack() like '%PLS-00485%' then
          begin
            execute immediate 'declare x positiven := -('||a_exception_name||'); begin null; end;';
            l_exception_type := gc_integer_exception;
            exception
            when others then
            --invalid exception number (positive)
            --TODO add warning for this value
            null;
          end;
        end if;
      end;
      return l_exception_type;
    end;

    function get_exception_number (a_exception_var in varchar2) return integer is
      l_exc_no   integer;
      l_exc_type varchar2(50);
      l_sql      varchar2(32767);
      function remap_no_data_found (a_number integer) return integer is
      begin
        return case a_number when 100 then -1403 else a_number end;
      end;
    begin
      l_exc_type := check_exception_type(a_exception_var);

      if l_exc_type is not null then

        execute immediate
        case l_exc_type
        when gc_integer_exception then
          'declare
            l_exception number;
          begin
            :l_exception := '||a_exception_var||'; '
        when gc_named_exception then
          'begin
            raise '||a_exception_var||';
          exception
            when others then
              :l_exception := sqlcode; '
        end ||
        'end;'
        using out l_exc_no;

      end if;
      return remap_no_data_found(l_exc_no);
    end;

    function build_exception_numbers_list(
      a_suite           in out nocopy ut_suite,
      a_procedure_name  t_object_name,
      a_line_no         integer,
      a_annotation_text in varchar2
    ) return ut_integer_list is
      l_throws_list             ut_varchar2_list;
      l_exception_number        integer;
      l_exception_number_list   ut_integer_list := ut_integer_list();
      c_regexp_for_exception_no constant varchar2(30) := '^-?[[:digit:]]{1,5}$';
    begin
      /*the a_expected_error_codes is converted to a ut_varchar2_list after that is trimmed and filtered to left only valid exception numbers*/
      l_throws_list := ut_utils.trim_list_elements(ut_utils.string_to_table(a_annotation_text, ',', 'Y'));

      for i in 1 .. l_throws_list.count
      loop
        /**
        * Check if its a valid qualified name and if so try to resolve name to an exception number
        */
        if is_valid_qualified_name(l_throws_list(i)) then
          l_exception_number := get_exception_number(l_throws_list(i));
        elsif regexp_like(l_throws_list(i), c_regexp_for_exception_no) then
          l_exception_number := l_throws_list(i);
        end if;

        if l_exception_number is null then
          a_suite.put_warning(
              'Invalid parameter value "'||l_throws_list(i)||'" for "--%throws" annotation. Parameter ignored.'
              || chr( 10 ) || 'at "' || get_qualified_object_name(a_suite, a_procedure_name) || '", line ' || a_line_no
          );
        else
          l_exception_number_list.extend;
          l_exception_number_list(l_exception_number_list.last) := l_exception_number;
        end if;
        l_exception_number := null;
      end loop;

      return l_exception_number_list;
    end;

  begin
    a_list := ut_integer_list();
    l_annotation_pos := a_throws_ann_text.first;
    while l_annotation_pos is not null loop
      if a_throws_ann_text(l_annotation_pos) is null then
        a_suite.put_warning(
            '"--%throws" annotation requires a parameter. Annotation ignored.'
            || chr( 10 ) || 'at "' || get_qualified_object_name(a_suite, a_procedure_name) || '", line ' || l_annotation_pos
        );
      else
        a_list :=
          a_list multiset union
          build_exception_numbers_list(
            a_suite,
            a_procedure_name,
            l_annotation_pos,
            a_throws_ann_text(l_annotation_pos)
          );
      end if;
      l_annotation_pos := a_throws_ann_text.next(l_annotation_pos);
    end loop;
  end;

  function convert_list(
    a_list tt_executables
  ) return ut_executables is
    l_result ut_executables := ut_executables();
    l_pos   t_annotation_position := a_list.first;
    begin
      while l_pos is not null loop
        l_result := l_result multiset union all a_list(l_pos);
        l_pos := a_list.next(l_pos);
      end loop;
      return l_result;
    end;

  function convert_list(
    a_list tt_tests
  ) return ut_suite_items is
    l_result ut_suite_items := ut_suite_items();
    l_pos   t_annotation_position := a_list.first;
    begin
      while l_pos is not null loop
        l_result.extend;
        l_result(l_result.last) := a_list(l_pos);
        l_pos := a_list.next(l_pos);
      end loop;
      return l_result;
    end;

  function add_executables(
    a_owner            t_object_name,
    a_package_name     t_object_name,
    a_annotation_texts tt_annotation_texts,
    a_event_name       ut_utils.t_event_name
  ) return tt_executables is
    l_executables     ut_executables;
    l_result          tt_executables;
    l_annotation_pos  binary_integer;
    l_procedures_list ut_varchar2_list;
    l_procedures_pos  binary_integer;
    l_components_list ut_varchar2_list;
  begin
    l_annotation_pos := a_annotation_texts.first;
    while l_annotation_pos is not null loop
      l_procedures_list :=
        ut_utils.filter_list(
          ut_utils.trim_list_elements(
            ut_utils.string_to_table(a_annotation_texts(l_annotation_pos), ',')
          )
          , '[[:alpha:]]+'
        );

      l_procedures_pos := l_procedures_list.first;
      l_executables := ut_executables();
      while l_procedures_pos is not null loop
        l_components_list := ut_utils.string_to_table(l_procedures_list(l_procedures_pos), '.');

        l_executables.extend;
        l_executables(l_executables.last) :=
          case(l_components_list.count())
            when 1 then
              ut_executable(a_owner, a_package_name, l_components_list(1), a_event_name)
            when 2 then
              ut_executable(a_owner,l_components_list(1), l_components_list(2), a_event_name)
            when 3 then
              ut_executable(l_components_list(1), l_components_list(2), l_components_list(3), a_event_name)
            else
              null
          end;
        l_procedures_pos := l_procedures_list.next(l_procedures_pos);
      end loop;
      l_result(l_annotation_pos) := l_executables;
      l_annotation_pos := a_annotation_texts.next(l_annotation_pos);
    end loop;
    return l_result;
  end;

  procedure warning_on_duplicate_annot(
    a_suite          in out nocopy ut_suite_item,
    a_annotations    tt_annotations_by_name,
    a_for_annotation varchar2,
    a_procedure_name  t_object_name := null
  ) is
    l_annotation_name t_annotation_name;
    l_line_no           binary_integer;
  begin
    if a_annotations.exists(a_for_annotation) then
      if a_annotations(a_for_annotation).count > 1 then
        --start from second occurrence of annotation
        l_line_no := a_annotations(a_for_annotation).next( a_annotations(a_for_annotation).first );
        while l_line_no is not null loop
          add_annotation_ignored_warning( a_suite, a_for_annotation, 'Duplicate annotation %%%.', l_line_no, a_procedure_name );
          l_line_no := a_annotations(a_for_annotation).next( l_line_no );
        end loop;
      end if;
    end if;
  end;

  procedure warning_bad_annot_combination(
    a_suite               in out nocopy ut_suite_item,
    a_procedure_name      t_object_name,
    a_proc_annotations    tt_annotations_by_name,
    a_for_annotation      varchar2,
    a_invalid_annotations ut_varchar2_list
  ) is
    l_annotation_name t_annotation_name;
    l_warning         varchar2(32767);
    l_line_no           binary_integer;
  begin
    if a_proc_annotations.exists(a_for_annotation) then
      l_annotation_name := a_proc_annotations.first;
      while l_annotation_name is not null loop
        if l_annotation_name member of a_invalid_annotations then
          l_line_no := a_proc_annotations(l_annotation_name).first;
          while l_line_no is not null loop
            add_annotation_ignored_warning(
                a_suite, l_annotation_name, 'Annotation %%% cannot be used with "--%'|| a_for_annotation || '".',
                l_line_no, a_procedure_name
            );
            l_line_no := a_proc_annotations(l_annotation_name).next(l_line_no);
          end loop;
        end if;
        l_annotation_name := a_proc_annotations.next(l_annotation_name);
      end loop;
    end if;
  end;

  procedure add_test(
    a_suite            in out nocopy ut_suite,
    a_tests            in out nocopy tt_tests,
    a_procedure_name   t_object_name,
    a_proc_annotations tt_annotations_by_name
  ) is
    l_test             ut_test;
    l_annotation_texts tt_annotation_texts;
    l_annotation_pos   binary_integer;
  begin
    if not a_proc_annotations.exists(gc_test) then
      return;
    end if;
    warning_on_duplicate_annot(a_suite, a_proc_annotations, gc_test, a_procedure_name);
    warning_on_duplicate_annot(a_suite, a_proc_annotations, gc_displayname, a_procedure_name);
    warning_on_duplicate_annot(a_suite, a_proc_annotations, gc_rollback, a_procedure_name);
    warning_bad_annot_combination(
        a_suite, a_procedure_name, a_proc_annotations, gc_test,
        ut_varchar2_list(gc_beforeeach, gc_aftereach, gc_beforeall, gc_afterall)
    );
    
    l_test := ut_test(a_suite.object_owner, a_suite.object_name, a_procedure_name);

    if a_proc_annotations.exists(gc_displayname) then
      l_annotation_texts := a_proc_annotations(gc_displayname);
      --take the last definition if more than one was provided
      l_test.description := l_annotation_texts(l_annotation_texts.first);
      --TODO if more than one - warning
    else
      l_test.description := a_proc_annotations(gc_test)(a_proc_annotations(gc_test).first);
    end if;
    l_test.path := a_suite.path ||'.'||a_procedure_name;

    if a_proc_annotations.exists(gc_rollback) then
      l_annotation_texts := a_proc_annotations(gc_rollback);
      l_test.rollback_type := get_rollback_type(l_annotation_texts(l_annotation_texts.first));
      if l_test.rollback_type is null then
        add_annotation_ignored_warning(
            a_suite, gc_rollback, 'Annotation %%% must be provided with one of values: "auto" or "manual".',
            l_annotation_texts.first, a_procedure_name
        );
      end if;
    end if;

    if a_proc_annotations.exists(gc_beforetest) then
      l_test.before_test_list := convert_list(
          add_executables( l_test.object_owner, l_test.object_name, a_proc_annotations( gc_beforetest ), gc_beforetest )
      );
    end if;
    if a_proc_annotations.exists(gc_aftertest) then
      l_test.after_test_list := convert_list(
          add_executables( l_test.object_owner, l_test.object_name, a_proc_annotations( gc_aftertest ), gc_aftertest )
      );
    end if;
    if a_proc_annotations.exists(gc_throws) then
      add_to_throws_numbers_list(a_suite, l_test.expected_error_codes, a_procedure_name, a_proc_annotations(gc_throws));
    end if;
    l_test.disabled_flag := ut_utils.boolean_to_int(a_proc_annotations.exists(gc_disabled));

    a_tests(a_proc_annotations(gc_test).first) := l_test;
  end;

  procedure update_before_after_each(
    a_suite in out nocopy ut_logical_suite,
    a_before_each_list tt_executables,
    a_after_each_list  tt_executables
  ) is
    l_test      ut_test;
    l_context   ut_logical_suite;
  begin
    if a_suite.items is not null then
      for i in 1 .. a_suite.items.count loop
        if a_suite.items(i) is of (ut_test) then
          l_test := treat( a_suite.items(i) as ut_test);
          l_test.before_each_list := coalesce(convert_list(a_before_each_list),ut_executables()) multiset union all l_test.before_each_list;
          l_test.after_each_list := l_test.after_each_list multiset union all coalesce(convert_list(a_after_each_list),ut_executables());
          a_suite.items(i) := l_test;
        elsif a_suite.items(i) is of (ut_logical_suite) then
          l_context := treat(a_suite.items(i) as ut_logical_suite);
          update_before_after_each(l_context, a_before_each_list, a_after_each_list);
          a_suite.items(i) := l_context;
        end if;
      end loop;
    end if;
  end;

  procedure process_before_after_annot(
    a_list             in out nocopy tt_executables,
    a_annotation_name  t_annotation_name,
    a_procedure_name   t_object_name,
    a_proc_annotations tt_annotations_by_name,
    a_suite            in out nocopy ut_suite
  ) is 
  begin
    if a_proc_annotations.exists(a_annotation_name) and not a_proc_annotations.exists(gc_test) then
      a_list( a_proc_annotations(a_annotation_name).first ) := ut_executables(ut_executable(a_suite.object_owner,  a_suite.object_name, a_procedure_name, a_annotation_name));
      warning_on_duplicate_annot(a_suite, a_proc_annotations, a_annotation_name, a_procedure_name);
    --TODO add warning if annotation has text - text ignored
    end if;
  end;

  procedure add_annotated_procedures(
    a_proc_annotations tt_annotations_by_proc,
    a_suite            in out nocopy ut_suite,
    a_before_each_list in out nocopy tt_executables,
    a_after_each_list  in out nocopy tt_executables,
    a_before_all_list  in out nocopy tt_executables,
    a_after_all_list   in out nocopy tt_executables
  ) is
    l_procedure_name   t_object_name;
    l_tests            tt_tests;
  begin
    l_procedure_name := a_proc_annotations.first;
    while l_procedure_name is not null loop
      add_test( a_suite, l_tests, l_procedure_name, a_proc_annotations(l_procedure_name) );
      process_before_after_annot(a_before_each_list, gc_beforeeach, l_procedure_name, a_proc_annotations(l_procedure_name), a_suite);
      process_before_after_annot(a_after_each_list,  gc_aftereach,  l_procedure_name, a_proc_annotations(l_procedure_name), a_suite);
      process_before_after_annot(a_before_all_list,  gc_beforeall,  l_procedure_name, a_proc_annotations(l_procedure_name), a_suite);
      process_before_after_annot(a_after_all_list,   gc_afterall,   l_procedure_name, a_proc_annotations(l_procedure_name), a_suite);
      l_procedure_name := a_proc_annotations.next( l_procedure_name );
    end loop;
    a_suite.items := a_suite.items multiset union all convert_list(l_tests);
  end;

  procedure build_suitepath(
    a_suite              in out nocopy ut_suite,
    a_annotations        t_annotations_info
  ) is
    l_annotation_text    t_annotation_text;
  begin
    if a_annotations.by_name.exists(gc_suitepath) then
      l_annotation_text := trim(a_annotations.by_name(gc_suitepath)(a_annotations.by_name(gc_suitepath).first));
      if l_annotation_text is not null then
        if regexp_like(l_annotation_text,'^((\w|[$#])+\.)*(\w|[$#])+$') then
          a_suite.path := l_annotation_text||'.'||a_suite.object_name;
        else
          add_annotation_ignored_warning(
              a_suite, gc_suitepath||'('||l_annotation_text||')',
              'Invalid path value in annotation %%%.', a_annotations.by_name(gc_suitepath).first
          );
        end if;
      else
        add_annotation_ignored_warning(
            a_suite, gc_suitepath, '%%% annotation requires a non-empty parameter value.',
            a_annotations.by_name(gc_suitepath).first
        );
      end if;
      warning_on_duplicate_annot(a_suite, a_annotations.by_name, gc_suitepath);
    end if;
    a_suite.path := lower(coalesce(a_suite.path, a_suite.object_name));
  end;

  procedure populate_suite_contents(
    a_suite              in out nocopy ut_suite,
    a_annotations        t_annotations_info
  ) is
    l_before_each_list   tt_executables;
    l_after_each_list    tt_executables;
    l_before_all_list    tt_executables;
    l_after_all_list     tt_executables;
    l_executables        ut_executables;
    l_rollback_type      ut_utils.t_rollback_type;
    l_annotation_text    t_annotation_text;
  begin
    if a_annotations.by_name.exists(gc_displayname) then
      l_annotation_text := trim(a_annotations.by_name(gc_displayname)(a_annotations.by_name(gc_displayname).first));
      if l_annotation_text is not null then
        a_suite.description := l_annotation_text;
      else
        add_annotation_ignored_warning(
            a_suite, gc_displayname, '%%% annotation requires a non-empty parameter value.',
            a_annotations.by_name(gc_displayname).first
        );
      end if;
      warning_on_duplicate_annot(a_suite, a_annotations.by_name, gc_displayname);
    end if;

    if a_annotations.by_name.exists(gc_rollback) then
      l_rollback_type := get_rollback_type(a_annotations.by_name(gc_rollback)(a_annotations.by_name(gc_rollback).first));
      if l_rollback_type is null then
        add_annotation_ignored_warning(
            a_suite, gc_rollback, '%%% annotation requires one of values as parameter: "auto" or "manual".',
            a_annotations.by_name(gc_rollback).first
        );
      end if;
      warning_on_duplicate_annot(a_suite, a_annotations.by_name, gc_rollback);
    end if;
    if a_annotations.by_name.exists(gc_beforeall) then
      l_before_all_list := add_executables( a_suite.object_owner, a_suite.object_name, a_annotations.by_name(gc_beforeall), gc_beforeall );
    end if;
    if a_annotations.by_name.exists(gc_afterall) then
      l_after_all_list := add_executables( a_suite.object_owner, a_suite.object_name, a_annotations.by_name(gc_afterall), gc_afterall );
    end if;

    if a_annotations.by_name.exists(gc_beforeeach) then
      l_before_each_list := add_executables( a_suite.object_owner, a_suite.object_name, a_annotations.by_name(gc_beforeeach), gc_beforeeach );
    end if;
    if a_annotations.by_name.exists(gc_aftereach) then
      l_after_each_list := add_executables( a_suite.object_owner, a_suite.object_name, a_annotations.by_name(gc_aftereach), gc_aftereach );
    end if;

    a_suite.disabled_flag := ut_utils.boolean_to_int(a_annotations.by_name.exists(gc_disabled));

    --process procedure annotations for suite
    add_annotated_procedures(a_annotations.by_proc, a_suite, l_before_each_list, l_after_each_list, l_before_all_list, l_after_all_list);

    a_suite.set_rollback_type(l_rollback_type);
    update_before_after_each(a_suite, l_before_each_list, l_after_each_list);
    a_suite.before_all_list := convert_list(l_before_all_list);
    a_suite.after_all_list  := convert_list(l_after_all_list);
  end;


  procedure add_suite_contexts(
    a_suite              in out nocopy ut_suite,
    a_annotations        in out nocopy t_annotations_info
  ) is
    l_context_pos        t_annotation_position;
    l_end_context_pos    t_annotation_position;
    l_context_name       t_object_name;
    l_ctx_annotations    t_annotations_info;
    l_context            ut_suite_context;
    l_context_no         binary_integer := 1;

    function get_endcontext_position(
      a_context_ann_pos     t_annotation_position,
      a_package_annotations in out nocopy tt_annotations_by_name
    ) return t_annotation_position is
      l_result t_annotation_position;
    begin
      if a_package_annotations.exists(gc_endcontext) then
        l_result := a_package_annotations(gc_endcontext).first;
        while l_result <= a_context_ann_pos loop
          l_result := a_package_annotations(gc_endcontext).next(l_result);
        end loop;
      end if;
      return l_result;
    end;

    function get_annotations_in_context(
      a_annotations        t_annotations_info,
      a_context_pos        t_annotation_position,
      a_end_context_pos    t_annotation_position
    ) return t_annotations_info is
      l_result          t_annotations_info;
      l_position        t_annotation_position;
      l_procedure_name  t_object_name;
      l_annotation_name t_annotation_name;
      l_annotation_text t_annotation_text;
    begin
      l_position := a_context_pos;
      l_result.owner := a_annotations.owner;
      l_result.name := a_annotations.name;
      while l_position is not null and l_position <= a_end_context_pos loop
        l_result.by_line(l_position) := a_annotations.by_line(l_position);
        l_procedure_name  := l_result.by_line(l_position).procedure_name;
        l_annotation_name := l_result.by_line(l_position).name;
        l_annotation_text := l_result.by_line(l_position).text;
        if l_procedure_name is not null then
          l_result.by_proc(l_procedure_name)(l_annotation_name)(l_position) := l_annotation_text;
        else
          l_result.by_name(l_annotation_name)(l_position) := l_annotation_text;
        end if;
        l_position := a_annotations.by_line.next(l_position);
      end loop;
      return l_result;
    end;

  begin
    if not a_annotations.by_name.exists(gc_context) then
      return;
    end if;

    l_context_pos := a_annotations.by_name( gc_context).first;

    while l_context_pos is not null loop
      l_end_context_pos := get_endcontext_position(l_context_pos, a_annotations.by_name );
      if l_end_context_pos is null then
        exit;
      end if;

      --create a sub-set of annotations to process as sub-suite (context)
      l_ctx_annotations   := get_annotations_in_context( a_annotations, l_context_pos, l_end_context_pos);

      l_context_name := coalesce(
        l_ctx_annotations.by_line( l_context_pos ).text
        , gc_context||'_'||l_context_no
      );

      l_context := ut_suite_context(a_suite.object_owner, a_suite.object_name, l_context_name );

      l_context.path := a_suite.path||'.'||l_context_name;
      l_context.description := l_ctx_annotations.by_line( l_context_pos ).text;

      warning_on_duplicate_annot( l_context, l_ctx_annotations.by_name, gc_context );

      populate_suite_contents( l_context, l_ctx_annotations );

      a_suite.add_item(l_context);

      -- remove annotations within context after processing them
      delete_annotations_range(a_annotations, l_context_pos, l_end_context_pos);

      exit when not a_annotations.by_name.exists( gc_context);

      l_context_pos := a_annotations.by_name( gc_context).next( l_context_pos);
      l_context_no := l_context_no + 1;
    end loop;
  end;

  procedure warning_on_incomplete_context(
    a_suite              in out nocopy ut_suite,
    a_package_ann_index  tt_annotations_by_name
  ) is
    l_annotation_pos  t_annotation_position;
  begin
    if a_package_ann_index.exists(gc_context) then
      l_annotation_pos := a_package_ann_index(gc_context).first;
      while l_annotation_pos is not null loop
        add_annotation_ignored_warning(
            a_suite, gc_context, 'Invalid annotation %%%. Cannot find following "--%endcontext".',
            l_annotation_pos
        );
        l_annotation_pos := a_package_ann_index(gc_context).next(l_annotation_pos);
      end loop;
    end if;
    if a_package_ann_index.exists(gc_endcontext) then
      l_annotation_pos := a_package_ann_index(gc_endcontext).first;
      while l_annotation_pos is not null loop
        add_annotation_ignored_warning(
            a_suite, gc_endcontext, 'Invalid annotation %%%. Cannot find preceding "--%context".',
            l_annotation_pos
        );
        l_annotation_pos := a_package_ann_index(gc_endcontext).next(l_annotation_pos);
      end loop;
    end if;
  end;

  procedure warning_on_unknown_annotations(
    a_suite in out nocopy ut_suite_item,
    a_annotations tt_annotations_by_line
  ) is
    l_line_no t_annotation_position :=  a_annotations.first;
  begin
    while l_line_no is not null loop
      if a_annotations(l_line_no).name not member of (gc_supported_annotations) then
        add_annotation_ignored_warning(
            a_suite,
            a_annotations(l_line_no).name,
            'Unsupported annotation %%%.',
            l_line_no,
            a_annotations(l_line_no).procedure_name
        );
      end if;
      l_line_no := a_annotations.next(l_line_no);
    end loop;
  end;

  function create_suite(
    a_annotations t_annotations_info
  ) return ut_logical_suite is
    l_annotations    t_annotations_info := a_annotations;
    l_annotation_pos t_annotation_position;
    l_suite          ut_suite;
  begin
    if l_annotations.by_name.exists( gc_suite) then

      --create an incomplete suite
      l_suite := ut_suite(l_annotations.owner, l_annotations.name);
      l_annotation_pos := l_annotations.by_name( gc_suite).first;
      l_suite.description := l_annotations.by_name( gc_suite)( l_annotation_pos);
      warning_on_unknown_annotations(l_suite, l_annotations.by_line);

      warning_on_duplicate_annot( l_suite, l_annotations.by_name, gc_suite );

      build_suitepath( l_suite, l_annotations );

      add_suite_contexts( l_suite, l_annotations );
      --by this time all contexts were consumed and l_annotations should not have any context/endcontext annotation in it.
      warning_on_incomplete_context( l_suite, l_annotations.by_name );

      populate_suite_contents( l_suite, l_annotations );

    end if;
    return l_suite;
  end;

  function build_suites_hierarchy(a_suites_by_path tt_schema_suites) return tt_schema_suites is
    l_result            tt_schema_suites;
    l_suite_path        varchar2(4000 char);
    l_parent_path       varchar2(4000 char);
    l_name              varchar2(4000 char);
    l_suites_by_path    tt_schema_suites;
  begin
    l_suites_by_path := a_suites_by_path;
    --were iterating in reverse order of the index by path table
    -- so the first paths will be the leafs of hierarchy and next will their parents
    l_suite_path  := l_suites_by_path.last;
    ut_utils.debug_log('Input suites to process = '||l_suites_by_path.count);

    while l_suite_path is not null loop
      l_parent_path := substr( l_suite_path, 1, instr(l_suite_path,'.',-1)-1);
      ut_utils.debug_log('Processing l_suite_path = "'||l_suite_path||'", l_parent_path = "'||l_parent_path||'"');
      --no parent => I'm a root element
      if l_parent_path is null then
        ut_utils.debug_log('  suite "'||l_suite_path||'" is a root element - adding to return list.');
        l_result(l_suite_path) := l_suites_by_path(l_suite_path);
      -- not a root suite - need to add it to a parent suite
      else
        --parent does not exist and needs to be added
        if not l_suites_by_path.exists(l_parent_path) then
          l_name  := substr( l_parent_path, instr(l_parent_path,'.',-1)+1);
          ut_utils.debug_log('  Parent suite "'||l_parent_path||'" not found in the list - Adding suite "'||l_name||'"');
          l_suites_by_path(l_parent_path) :=
            ut_logical_suite(
              a_object_owner => l_suites_by_path(l_suite_path).object_owner,
              a_object_name => l_name, a_name => l_name, a_path => l_parent_path
            );
        else
          ut_utils.debug_log('  Parent suite "'||l_parent_path||'" found in list of suites');
        end if;
        ut_utils.debug_log('  adding suite "'||l_suite_path||'" to "'||l_parent_path||'" items');
        l_suites_by_path(l_parent_path).add_item( l_suites_by_path(l_suite_path) );
      end if;
      l_suite_path := l_suites_by_path.prior(l_suite_path);
    end loop;
    ut_utils.debug_log(l_result.count||' root suites created.');
    return l_result;
  end;

  function build_suites(a_annotated_objects sys_refcursor) return t_schema_suites_info is
    l_suite             ut_logical_suite;
    l_annotated_objects ut_annotated_objects;
    l_all_suites        tt_schema_suites;
    l_result            t_schema_suites_info;

    function convert_package_annotations(a_object ut_annotated_object) return t_annotations_info is
      l_result          t_annotations_info;
      l_annotation      t_annotation;
      l_annotation_no   binary_integer;
      l_annotation_pos  binary_integer;
    begin
      l_result.owner := a_object.object_owner;
      l_result.name  := lower(trim(a_object.object_name));
      l_annotation_no := a_object.annotations.first;
      while l_annotation_no is not null loop
        l_annotation_pos := a_object.annotations(l_annotation_no).position;
        l_annotation.name := a_object.annotations(l_annotation_no).name;
        l_annotation.text := a_object.annotations(l_annotation_no).text;
        l_annotation.procedure_name := lower(trim(a_object.annotations(l_annotation_no).subobject_name));
        l_result.by_line( l_annotation_pos) := l_annotation;
        if l_annotation.procedure_name is null then
          l_result.by_name( l_annotation.name)( l_annotation_pos) := l_annotation.text;
        else
          l_result.by_proc(l_annotation.procedure_name)(l_annotation.name)(l_annotation_pos) := l_annotation.text;
        end if;
        l_annotation_no := a_object.annotations.next(l_annotation_no);
      end loop;
      return l_result;
    end;

  begin
    fetch a_annotated_objects bulk collect into l_annotated_objects;
    close a_annotated_objects;

    for i in 1 .. l_annotated_objects.count loop
      l_suite := create_suite(convert_package_annotations(l_annotated_objects(i)));
      if l_suite is not null then
        l_all_suites(l_suite.path) := l_suite;
        l_result.suite_paths(l_suite.object_name) := l_suite.path;
      end if;
    end loop;

    --build hierarchical structure of the suite
    -- Restructure single-dimension list into hierarchy of suites by the value of %suitepath attribute value
    l_result.schema_suites := build_suites_hierarchy(l_all_suites);

    return l_result;
  end;

  function build_schema_suites(a_owner_name varchar2) return t_schema_suites_info is
    l_annotations_cursor sys_refcursor;
  begin
    -- form the single-dimension list of suites constructed from parsed packages
    open l_annotations_cursor for
      q'[select value(x)
          from table(
            ]'||ut_utils.ut_owner||q'[.ut_annotation_manager.get_annotated_objects(:a_owner_name, 'PACKAGE')
          )x ]'
      using a_owner_name;

    return build_suites(l_annotations_cursor);
  end;

end ut_suite_builder;
/
