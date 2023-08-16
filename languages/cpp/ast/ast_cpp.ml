(* Yoann Padioleau
 *
 * Copyright (C) 2002-2005 Yoann Padioleau
 * Copyright (C) 2006-2007 Ecole des Mines de Nantes
 * Copyright (C) 2008-2009 University of Urbana Champaign
 * Copyright (C) 2010-2014 Facebook
 * Copyright (C) 2019-2021 r2c
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* An Abstract Syntax Tree for C/C++/Cpp.
 *
 * This is a big file. C++ is a big and complicated language, and dealing
 * directly with preprocessor constructs from cpp makes the language
 * even bigger.
 *
 * This file started as a simple AST for C. It was then extended
 * to deal with cpp idioms (see 'cppext:' tag) and converted to a CST.
 * Then, it was extented again to deal with gcc extensions (see gccext:),
 * and C++ constructs (see c++ext:), and a few kencc (the plan9 compiler)
 * extensions (see kenccext:). Then, it was extended to deal with
 * a few C++0x (see c++0x:) and C++11 extensions (see c++11:).
 * Finally it was converted back to an AST (actually half AST, half CST)
 * for semgrep and to be the target of tree-sitter-cpp.
 *
 * gcc introduced StatementExpr which made 'expr' and 'stmt' mutually
 * recursive. It also added NestedFunc for even more mutual recursivity.
 * With C++ templates, because template arguments can be types or expressions
 * and because templates are also qualifiers, almost all types
 * are now mutually recursive ...
 *
 * Some stuff are tagged 'semantic:' which means that they can be computed
 * only after parsing.
 *
 * See also lang_c/parsing/ast_c.ml and lang_clang/parsing/ast_clang.ml
 * (as well as mini/ast_minic.ml).
 *
 * todo:
 *  - some things are tagged tsonly, meaning they are only generated by
 *    tree-sitter-cpp, but they should also be handled by parser_cpp.mly
 *
 * related work:
 *  - https://github.com/facebook/facebook-clang-plugins
 *    or https://github.com/Antique-team/clangml
 *    but by both using clang they work after preprocessing. This is
 *    fine for bug finding, but for codemap we need to parse as is,
 *    and we need to do it fast (calling clang is super expensive because
 *    calling cpp and parsing the end result is expensive)
 *  - EDG
 *  - see the CC'09 paper
 *)

(*****************************************************************************)
(* Tokens *)
(*****************************************************************************)

type tok = Tok.t [@@deriving show]

(* a shortcut to annotate some information with token/position information *)
type 'a wrap = 'a * tok [@@deriving show]
type 'a paren = tok * 'a * tok [@@deriving show]
type 'a brace = tok * 'a * tok [@@deriving show]
type 'a bracket = tok * 'a * tok [@@deriving show]
type 'a angle = tok * 'a * tok [@@deriving show]

(* semicolon *)
type sc = tok [@@deriving show]
type todo_category = string wrap [@@deriving show]

(*****************************************************************************)
(* Names *)
(*****************************************************************************)
(* Ident, name, scope qualifier *)

type ident = string wrap [@@deriving show]

(* c++ext: In C, 'name' and 'ident' are equivalent and are just strings.
 * In C++, 'name' can have a complex form like 'A::B::list<int>::size'.
 * I use Q for qualified. I also have a special type to make the difference
 * between intermediate idents (the classname or template_id) and final idents.
 * Note that sometimes final idents are also classnames and can have final
 * template_id.
 *
 * Sometimes some elements are not allowed at certain places, for instance
 * converters can not have an associated Qtop. But I prefered to simplify
 * and have a unique type for all those different kinds of names.
 *)
type name = tok (*::*) option * qualifier list * ident_or_op

and ident_or_op =
  (* function name, macro name, variable, classname, enumname, namespace *)
  | IdIdent of ident
  (* c++ext: *)
  | IdDestructor of tok (*~*) * ident
  (* c++ext: operator overloading *)
  | IdOperator of tok (* 'operator' *) * operator wrap
  | IdConverter of tok (* 'operator' *) * type_
  (* TODO: not recursive, so should be enforced by making
   * using 'ident_or_op * template_arguments option' in 'name' above. *)
  | IdTemplated of ident_or_op * template_arguments

and template_arguments = template_argument list angle

(* C++ allows integers for template arguments! (=~ dependent types) *)
and template_argument = (type_, expr) Common.either

and qualifier =
  | QClassname of ident (* a_class_name or a_namespace_name *)
  | QTemplateId of ident * template_arguments

(* special cases *)
and a_class_name = name (* only IdIdent or IdTemplateId *)
and a_ident_name = name (* only IdIdent *)
and a_namespace_name = name

(* less: do like in parsing_c/
 * and ident_string =
 *  | RegularName of string wrap
 *
 *  (* cppext: *)
 *  | CppConcatenatedName of (string wrap) wrap (* the ## separators *) list
 *  (* normally only used inside list of things, as in parameters or arguments
 *   * in which case, cf cpp-manual, it has a special meaning *)
 *  | CppVariadicName of string wrap (* ## s *)
 *  | CppIdentBuilder of string wrap (* s ( ) *) *
 *                      ((string wrap) wrap list) (* arguments *)
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)
(* We could have a more precise type in type_, in expression, etc, but
 * it would require too much things at parsing time such as checking whether
 * there is no conflicts structname, computing value, etc. It's better to
 * separate concerns, so I put '=>' to mean what we would really like. In fact
 * what we really like is defining another type_, expression, etc
 * from scratch, because many stuff are just sugar.
 *
 * invariant: Array and FunctionType have also typeQualifier but they
 * dont have sense. I put this to factorise some code. If you look in
 * grammar, you see that we can never specify const for the array
 * himself (but we can do it for pointer).
 *)
and type_ = type_qualifiers * typeC

and typeC =
  | TPrimitive of primitive_type wrap
  (* The list below is non empty and can contain duplicates.
   * Indeed, 'long long' is not the same than just 'long'.
   * The type_ below is either a TPrimitive or TypeName of IdIdent.
   *)
  | TSized of sized_type wrap list * type_ option (*  *)
  | TPointer of tok (*'*'*) * type_ * pointer_modifier list
  (* c++ext: *)
  | TReference of tok (*'&'*) * type_
  (* c++0x: *)
  | TRefRef of tok (*'&&'*) * type_
  | TArray of a_const_expr (* less: or star *) option bracket * type_
  | TFunction of functionType
  | EnumName of tok (* 'enum' *) * a_ident_name
  (* less: ms declspec option after struct/union *)
  | ClassName of class_key wrap * a_class_name
  (* c++ext: TypeName can now correspond also to a classname or enumname
   * and it is a name so it can have some IdTemplateId in it.
   *)
  | TypeName of a_ident_name
  (* only to disambiguate I think *)
  | TypenameKwd of tok (* 'typename' *) * type_ (* usually a TypeName *)
  (* should be really just at toplevel *)
  | EnumDef of enum_definition (* => string * int list *)
  (* c++ext: bigger type now *)
  | ClassDef of class_definition
  (* gccext: TypeOfType may seems useless, why declare a __typeof__(int)
   * x; ? But when used with macro, it allows to fix a problem of C which
   * is that type declaration can be spread around the ident. Indeed it
   * may be difficult to have a macro such as '#define macro(type,
   * ident) type ident;' because when you want to do a macro(char[256],
   * x), then it will generate invalid code, but with a '#define
   * macro(type, ident) __typeof(type) ident;' it will work. *)
  | TypeOf of tok * (type_, expr) Common.either paren
  (* c++0x: *)
  | TAuto of tok
  (* forunparser: *)
  | ParenType of type_ paren (* less: delete *)
  (* TODO: TypeDots, DeclType *)
  | TypeTodo of todo_category * type_ list

(* old: had a more precise 'intType' and 'floatType' with 'sign * base'
 * but not worth it, and tree-sitter-cpp allows any sized types
 * (maybe to handle cpp primitive type aliases? or some c++0x ext?).
 *
 * Note that certain types like size_t, ssize_t, int8_t are considered
 * primitive types by tree-sitter-c, but are converted in TypeName here.
 *)
and primitive_type = TVoid | TBool | TChar | TInt | TFloat | TDouble
and sized_type = TSigned | TUnsigned | TShort | TLong
and type_qualifiers = type_qualifier wrap list

(*****************************************************************************)
(* Expressions *)
(*****************************************************************************)
(* Because of StatementExpr, we can have more 'new scope', but it's
 * rare I think. For instance with 'array of constExpression' we could
 * have an StatementExpr and a new (local) struct defined. Same for
 * Constructor.
 *)
and expr =
  (* N can be an enumeration constant, variable, function name.
   * cppext: N can also be the name of a macro. sparse says
   *  "an identifier with a meaning is a symbol".
   * c++ext: N is now a 'name' instead of a 'string' and can be
   *  also an operator name.
   *)
  | N of name
  | C of constant
  | IdSpecial of special wrap
  (* I used to have FunCallSimple but not that useful, and we want scope info
   * for FunCallSimple too because can have fn(...) where fn is actually
   * a local *)
  | Call of expr * argument list paren
  (* gccext: x ? /* empty */ : y <=> x ? x : y; *)
  | CondExpr of expr * tok * expr option * tok * expr
  (* should be considered as statements, bad C language *)
  | Sequence of expr * tok (* , *) * expr
  | Assign of a_lhs * assignOp * expr
  | Prefix of fixOp wrap * expr
  | Postfix of expr * fixOp wrap
  (* contains GetRef and Deref!! less: lift up? *)
  | Unary of unaryOp wrap * expr
  | Binary of expr * binaryOp wrap * expr
  | ArrayAccess of expr * expr bracket
  (* name is usually just an ident_or_op. In rare cases it can be
   * a template_method name. *)
  | DotAccess of expr * dotOp wrap * name
  (* pfffonly, but we should add it to ts too.
   * c++ext: note that second paramater is an expr, not a name *)
  | DotStarAccess of expr * dotOp wrap (* with suffix '*' *) * expr
  | SizeOf of tok * (expr, type_ paren) Common.either
    (* TODO: SizeOfDots of tok * tok * ident paren ??? *)
  | Cast of type_ paren * expr
  (* gccext: *)
  | StatementExpr of compound paren (* ( {  } ) new scope*)
  (* gccext: kenccext: *)
  | GccConstructor of type_ paren * initialiser list brace
  (* c++ext: parens with TPrimitive and braces with TypeName *)
  | ConstructedObject of type_ * obj_init
  (* ?? *)
  | TypeId of tok * (type_, expr) Common.either paren
  | CplusplusCast of cast_operator wrap * type_ angle * expr paren
  | New of
      tok (*::*) option
      * tok (* 'new' *)
      * argument list paren option (* placement *)
      * type_
      * (* less: c++11? rectype option *)
      obj_init option (* initializer *)
  | Delete of tok (*::*) option * tok * unit bracket option * expr
  (* TODO: tsonly it's a stmt *)
  | Throw of tok * expr option
  (* c++11: finally! *)
  | Lambda of lambda_definition
  (* ?? tsonly: *)
  | ParamPackExpansion of expr * tok (* '...' *)
  (* forunparser: *)
  | ParenExpr of expr paren
  (* sgrep-ext: *)
  | Ellipsis of tok
  | DeepEllipsis of expr bracket
  | TypedMetavar of ident * type_
  | ExprTodo of todo_category * expr list

and special =
  (* c++ext: *)
  | This
  (* cppext: tsonly, always in a Call, with Id as single arg *)
  | Defined

(* cppext: normally should just have type argument = expr *)
and argument =
  | Arg of expr
  (* cppext: *)
  | ArgType of type_
  (* cppext: for really unparsable stuff ... we just bailout *)
  | ArgAction of action_macro
  (* c++0x? *)
  | ArgInits of initialiser list brace

and action_macro = ActMisc of tok list

(* Constants.
 * note: '-2' is not a constant; it is the unary operator '-'
 * applied to the constant '2'. So the string must represent a positive
 * integer only.
 * old: the Int and Float had a intType and floatType, and Char and
 * String had isWchar param, but not worth it.
 *)
and constant =
  | Int of int option wrap
  (* the wrap can contain the f/F/l/L suffix *)
  | Float of float option wrap
  | Char of string wrap (* normally it is equivalent to Int *)
  (* the wrap can contain the L/u/U/u8 prefix *)
  | String of string wrap (* TODO: bracket *)
  | MultiString of string wrap list
  (* can contain MacroString *)
  (* TODO: bracket *)
  (* c++ext: *)
  | Bool of bool wrap
  | Nullptr of tok

(* c++ext: *)
and cast_operator = Static_cast | Dynamic_cast | Const_cast | Reinterpret_cast

and unaryOp =
  | UnPlus
  | UnMinus
  | Tilde
  | Not
  (* TODO? lift up, those are really important operators *)
  | GetRef
  | DeRef
  (* gccext: via &&label notation *)
  | GetRefLabel

(* The Arrow is redundant; could be replaced by DeRef DotAccess *)
and dotOp =
  | Dot
  (* . *)
  | Arrow (* -> *)

(* ------------------------------------------------------------------------- *)
(* Overloaded operators *)
(* ------------------------------------------------------------------------- *)
and operator =
  | BinaryOp of binaryOp
  | AssignOp of assignOp
  | FixOp of fixOp
  | PtrOpOp of ptrOp
  | AccessOp of accessop
  | AllocOp of allocOp
  | UnaryTildeOp
  | UnaryNotOp
  | CommaOp

(* less: migrate to AST_generic_.op? *)
and binaryOp = Arith of arithOp | Logical of logicalOp

and arithOp =
  | Plus
  | Minus
  | Mul
  | Div
  | Mod
  | DecLeft
  | DecRight
  | And
  | Or
  | Xor

and logicalOp = Inf | Sup | InfEq | SupEq | Eq | NotEq | AndLog | OrLog
and assignOp = SimpleAssign of tok | OpAssign of arithOp wrap

(* less: migrate to AST_generic_.incr_decr? *)
and fixOp = Dec | Inc

(* c++ext: used elsewhere but prefer to define it close to other operators *)
and ptrOp = PtrStarOp | PtrOp
and accessop = ParenOp | ArrayOp
and allocOp = NewOp | DeleteOp | NewArrayOp | DeleteArrayOp

(* ------------------------------------------------------------------------- *)
(* Aliases *)
(* ------------------------------------------------------------------------- *)
and a_const_expr = expr (* => int *)

(* expr subset: Id, XxxAccess, Deref, ParenExpr, ...*)
and a_lhs = expr

(*****************************************************************************)
(* Statements *)
(*****************************************************************************)
(* note: assignement is not a statement, it's an expr :(
 * (wonderful C language).
 * note: I use 'and' for type definition because gccext allows statements as
 * expressions, so we need mutual recursive type definition now.
 *)
and stmt =
  | Compound of compound (* new scope *)
  | ExprStmt of expr_stmt
  (* cppext: *)
  | MacroStmt of tok
  (* selection *)
  | If of
      tok
      * tok (* 'constexpr' *) option
      * condition_clause paren
      * stmt
      * (tok * stmt) option
  (* need to check that all elements in the compound start
   * with a case:, otherwise it's unreachable code.
   *)
  | Switch of tok * condition_clause paren * stmt (* always a compound? *)
  (* iteration *)
  | While of tok * condition_clause paren * stmt
  | DoWhile of tok * stmt * tok * expr paren * sc
  | For of tok * for_header paren * stmt
  (* cppext: *)
  | MacroIteration of ident * argument list paren * stmt
  | Jump of jump * sc
  (* labeled *)
  | Label of a_label * tok (* : *) * stmt
  (* TODO: only inside Switch in theory *)
  | Case of tok * expr * tok (* : *) * case_body
  (* gccext: *)
  | CaseRange of tok * expr * tok (* ... *) * expr * tok (* : *) * case_body
  | Default of tok * tok (* : *) * case_body
  (* c++ext: *)
  | Try of tok * compound * handler list
  (* old: c++ext: gccext: there was a DeclStmt and NestedFunc before, but they
   * are now handled by stmt_or_decl *)
  | StmtTodo of todo_category * stmt list

and expr_stmt = expr option * sc

and condition_clause =
  | CondClassic of expr
  (* c++ext: *)
  | CondDecl of vars_decl * expr
  | CondStmt of expr_stmt * expr
  (* TODO? can have also StructuredBinding? switch to onedecl? *)
  | CondOneDecl of var_decl (* vinit always Some *)

and for_header =
  | ForClassic of a_expr_or_vars * expr option * expr option
  (* c++0x? TODO: var_decl can be DStructrured_binding with vinit = None  *)
  | ForRange of var_decl (* vinit = None *) * tok (*':'*) * initialiser
  (* sgrep-ext: *)
  | ForEllipsis of tok (* ... *)

and a_expr_or_vars = (expr_stmt, vars_decl) Common.either
and a_label = string wrap

and jump =
  | Goto of tok * a_label
  | Continue of tok
  | Break of tok
  | Return of tok * argument (* just Arg or ArgInits *) option
  (* gccext: goto *exp *)
  | GotoComputed of tok * tok * expr

(* Note that pfff and tree-sitter-cpp parses differently cases.
 * So 'case 1: case 2: i++; break;' is parsed as:
 * - [Case (1, []); (Case (2, [i++; break]))] in tree-sitter
 * - [Case (1, [Case (2, i++)]); break] in pfff
 * so lots of work has to be done to make this consistent in
 * cpp_to_generic.ml
 * The decl below can actually only be a DeclList.
 *)
and case_body = stmt_or_decl list

(* c++ext: *)
and handler = tok (* 'catch' *) * exception_declaration paren * compound
and exception_declaration = ExnDecl of parameter

(*****************************************************************************)
(* Stmt or Decl *)
(*****************************************************************************)
and stmt_or_decl = S of stmt | D of decl

(* cppext: c++ext:
 * old: (declaration list * stmt list)
 * old: (declaration, stmt) either list
 * old: smt sequencable list brace, with a DeclStmt of block_declaration
 *  in the stmt type.
 *)
and compound = stmt_or_decl sequencable list brace

(* In theory we should restrict to just decl, but tree-sitter-cpp is more
 * general and accept also stmts *)
and declarations = stmt_or_decl sequencable list brace

(*****************************************************************************)
(* Definitions/Declarations *)
(*****************************************************************************)

(* see also ClassDef/EnumDef in type_ which can also define entities *)
and entity = {
  (* Usually a simple ident.
   * Can be an ident_or_op for functions
   *)
  name : name;
  specs : specifier list;
}

(* ------------------------------------------------------------------------- *)
(* Decl *)
(* ------------------------------------------------------------------------- *)

(* It's not really 'toplevel' because the elements below can be nested
 * inside namespaces or some extern. It's not really 'declaration'
 * either because it can defines stuff. But I keep the C++ standard
 * terminology.
 *
 * old: was split in intermediate 'block_declaration' before.
 *)
and decl =
  (* Before I had a Typedef constructor, but why make this special case and not
   * have also StructDef, EnumDef, so that 'struct t {...} v' which would
   * then generate two declarations.
   * If you want a cleaner C AST use ast_c.ml.
   * update: I actually moved out Typedef at least out of var_decl now.
   * note: before the need for unparser, I didn't have a DeclList but just
   * a Decl.
   *)
  | DeclList of vars_decl
  | Func of func_definition
  (* c++ext: *)
  | TemplateDecl of tok * template_parameters * decl
  | TemplateInstanciation of tok (* 'template' *) * var_decl (*vinit=None*) * sc
  (* c++ext: using namespace *)
  | UsingDecl of using
  (* pfff-only: but should be added to ts too *)
  | NamespaceAlias of
      tok (*'namespace'*) * ident * tok (*=*) * a_namespace_name * sc
  (* the list can be empty *)
  | Namespace of tok * ident option * declarations
  (* the list can be empty *)
  | ExternDecl of tok * string wrap (* usually "C" *) * decl
  | ExternList of tok * string wrap * declarations
  (* gccext: *)
  | Asm of tok * tok option (*volatile*) * asmbody paren * sc
  (* c++0x?: tsonly: at toplevel or in class *)
  | StaticAssert of tok * argument list paren (* last args are strings *)
  (* gccext: allow redundant ';' *)
  | EmptyDef of sc
  | NotParsedCorrectly of tok list
  | DeclTodo of todo_category

(* gccext: *)
and asmbody = string wrap list * colon list
and colon = Colon of tok (* : *) * colon_option list
and colon_option = ColonExpr of tok list * expr paren | ColonMisc of tok list

(* ------------------------------------------------------------------------- *)
(* Vars_decl and onedecl *)
(* ------------------------------------------------------------------------- *)
and vars_decl = onedecl list * sc

(* note: onedecl includes prototype declarations and class_declarations!
 * c++ext: onedecl now covers also field definitions as fields can have
 * storage in C++.
 *)
and onedecl =
  | TypedefDecl of tok (*'typedef'*) * type_ * ident
  (* You can have empty declaration or struct tag declaration.
   * kenccext: you can also have anonymous fields.
   *)
  | EmptyDecl of type_
  (* This covers variables but also fields.
   * old: there was a separate 'FieldDecl of fieldkind' before,
   * like DeclList, but simpler to reuse onedecl.
   * c++ext: FieldDecl was before Simple of string option * type_
   * but in c++ fields can also have storage (e.g. static) so again simpler
   * to reuse onedecl.
   *)
  | V of var_decl
  (* c++17: structured binding, [n1, n2, n3] = expr *)
  | StructuredBinding of type_ * ident list bracket * init
  (* BitField can appear only inside struct/classes in class_member.
   * At first I thought that a bitfield could be only Signed/Unsigned.
   * But it seems that gcc allows char i:4. C rule must say that you
   * can cast into int so enum too, ...
   *)
  | BitField of ident option * tok (*:*) * type_ * a_const_expr
(* type_ => BitFieldInt | BitFieldUnsigned *)

(* ------------------------------------------------------------------------- *)
(* Variable definition (and also field definition) *)
(* ------------------------------------------------------------------------- *)

and var_decl = entity * variable_definition
and variable_definition = { v_init : init option; v_type : type_ }

and init =
  | EqInit of tok (*=*) * initialiser
  (* c++ext: constructed object *)
  | ObjInit of obj_init
  (* only for fields *)
  | Bitfield of tok (* : *) * a_const_expr

and obj_init = Args of argument list paren | Inits of initialiser list brace

and initialiser =
  (* in lhs and rhs *)
  | InitExpr of expr
  | InitList of initialiser list brace
  (* gccext: and only in lhs *)
  | InitDesignators of designator list * tok (*=*) * initialiser
  | InitFieldOld of ident * tok (*:*) * initialiser
  | InitIndexOld of expr bracket * initialiser

(* ex: [2].y = x,  or .y[2]  or .y.x. They can be nested *)
and designator =
  | DesignatorField of tok (* . *) * ident
  | DesignatorIndex of expr bracket
  | DesignatorRange of (expr * tok (*...*) * expr) bracket

(* ------------------------------------------------------------------------- *)
(* Function/method/ctor/dtor definition/declaration *)
(* ------------------------------------------------------------------------- *)
(* I used to separate functions from methods from ctor/dtor, but simpler
 * to just use one type. The entity will say if it's a ctor/dtor.
 *
 * invariant:
 *  - if dtor, then f_params = [] or [TVoid].
 *  - if ctor/dtor, f_ret should be fake void.
 *
 * less: can maybe factorize annotations in this entity type (e.g., storage).
 *)
and func_definition = entity * function_definition

and function_definition = {
  (* Normally we should define another type functionType2 because there
   * are more restrictions on what can define a function than a pointer
   * function. For instance a function declaration can omit the name of the
   * parameter whereas a function definition can not. But, in some cases such
   * as 'f(void) {', there is no name too, so I simplified and reused the
   * same functionType type for both declarations and function definitions.
   *)
  f_type : functionType;
  (* TODO: chain call for ctor or put in function body? *)
  f_body : function_body;
  (* we could use the specs in entity, but for Lambdas there are no entity *)
  f_specs : specifier list; (* gccext: *)
}

and functionType = {
  ft_ret : type_; (* fake return type for ctor/dtor *)
  ft_params : parameter list paren;
  ft_specs : specifier list;
  (* c++ext: *)
  ft_const : tok option; (* only for methods, TODO put in attribute? *)
  ft_throw : exn_spec list;
}

and parameter =
  | P of parameter_classic
  (* c++0x?? *)
  | ParamVariadic of
      tok option (* &/&& *)
      * tok (* ... *)
      * parameter_classic (* p_val = None and p_name = None *)
  (* sgrep-ext: also part of C, in which case it must be the last parameter *)
  | ParamEllipsis of tok
  (* e.g., multi parameter exn handler (tsonly) *)
  | ParamTodo of todo_category * parameter list

and parameter_classic = {
  p_name : ident option;
  p_type : type_;
  p_specs : specifier list;
  (* c++ext: *)
  p_val : (tok (*=*) * expr) option;
}

and exn_spec =
  (* c++ext: *)
  | ThrowSpec of tok (*'throw'*) * type_ (* usually just a name *) list paren
  (* c++11: *)
  | Noexcept of tok * a_const_expr option paren option

and function_body =
  | FBDef of compound
  (* TODO? FBDefCtor of field_initializer * compound *)
  (* TODO: prototype, but can also be hidden in a DeclList! *)
  | FBDecl of sc
  (* c++ext: only for methods *)
  | FBZero of tok (* '=' *) * tok (* '0' *) * sc
  (* c++11: defaulted functions *)
  | FBDefault of tok (* '=' *) * tok (* 'default' *) * sc
  (* c++11: deleted functions *)
  | FBDelete of tok (* '=' *) * tok (* 'delete' *) * sc

and lambda_definition = lambda_capture list bracket * function_definition

and lambda_capture =
  | CaptureEq of tok (* '=' *)
  | CaptureRef of tok (* '&' *)
  (* expr can be: id, &id, this, *this, args..., x = foo(), etc. *)
  | CaptureOther of expr

(* ------------------------------------------------------------------------- *)
(* enum definition *)
(* ------------------------------------------------------------------------- *)
and enum_definition = {
  enum_kind : tok; (* 'enum'  TODO also enum class/struct *)
  enum_name : name option;
  (* TODO: enum_base: *)
  enum_body : enum_elem list brace;
}

and enum_elem = { e_name : ident; e_val : (tok (*=*) * a_const_expr) option }

(* ------------------------------------------------------------------------- *)
(* Class definition *)
(* ------------------------------------------------------------------------- *)
(* the ident can be a template_id when do template specialization. *)
and class_definition = a_class_name option * class_definition_bis

and class_definition_bis = {
  c_kind : class_key wrap;
  (* c++ext: *)
  c_inherit : base_clause list;
  c_members : class_member sequencable list brace (* new scope *);
}

and class_key =
  (* classic C *)
  | Struct
  | Union
  (* c++ext: *)
  | Class

and base_clause = {
  i_name : a_class_name;
  (* TODO: i_specs? i_dots ? *)
  i_virtual : modifier option; (* tsonly: final/override, pfff: ?  *)
  i_access : access_spec wrap option;
}

(* old:was called 'field wrap' before *)
and class_member =
  (* could put outside and take class_member list *)
  | Access of access_spec wrap * tok (*:*)
  | Friend of tok (* 'friend' *) * decl (* Func or DeclList *)
  | QualifiedIdInClass of name (* ?? *) * sc
  (* valid declarations in class_member:
   * DeclList/Func(for methods)/TemplateDecl/UsingDecl/EmptyDef/...
   *)
  | F of decl

(* ------------------------------------------------------------------------- *)
(* Template definition/declaration *)
(* ------------------------------------------------------------------------- *)

(* see also template_arguments in name section *)

(* c++ext: *)
and template_parameter =
  | TP of parameter
  | TPClass of
      tok (* 'class/typename' *) * ident option * (* '=' *) type_ option
  | TPVariadic of tok (* 'class/typename'*) * tok (* '...' *) * ident option
  (* ??? *)
  | TPNested of
      tok (* 'template' *)
      * template_parameters
      * template_parameter (* not TPNested *)

and template_parameters = template_parameter list angle

(*****************************************************************************)
(* Attributes, modifiers *)
(*****************************************************************************)
(* not a great name, but the C++ grammar often uses that term *)
and specifier =
  | A of attribute
  | M of modifier
  | TQ of type_qualifier wrap
  | ST of storage wrap

and attribute =
  (* gccext? __attribute__((...)), double paren *)
  | UnderscoresAttr of tok (* __attribute__ *) * argument list paren paren
  (* c++0x? [[ ... ]], double bracket *)
  | BracketsAttr of expr list bracket (* actually double [[ ]] *)
  (* msext: __declspec(id) *)
  | DeclSpec of tok * ident paren

and modifier =
  (* what is a prototype inline?? gcc accepts it. *)
  | Inline of tok
  (* virtual specifier *)
  | Virtual of tok
  | Final of tok
  | Override of tok
  (* msext: just for functions *)
  | MsCall of string wrap (* msext: e.g., __cdecl, __stdcall *)
  (* c++ext: just for constructor *)
  | Explicit of tok (* 'explicit' *) * expr paren option

(* used in inheritance spec (base_clause) and class_member *)
and access_spec = Public | Private | Protected

and type_qualifier =
  (* classic C type qualifiers *)
  | Const
  | Volatile
  (* cext? *)
  | Restrict
  | Atomic
  (* c++ext? *)
  | Mutable
  | Constexpr

and storage =
  (* only in C, in C++ auto is for TAuto *)
  | Auto
  | Static
  | Register
  | Extern
  (* c++0x? *)
  | StoInline
(* Friend ???? Mutable? *)

(* only in declarator (not in abstract declarator) *)
and pointer_modifier =
  (* msext: tsonly: *)
  | Based of tok (* '__based' *) * argument list paren
  | PtrRestrict of tok (* '__restrict' *)
  | Uptr of tok (* '__uptr' *)
  | Sptr of tok (* '__sptr' *)
  | Unaligned of tok

(*****************************************************************************)
(* Namespace (using) *)
(*****************************************************************************)
and using = tok (*'using'*) * using_kind * sc

(* Actually 'using' is used for very different things in C++ (because the
 * C++ committee hates introduce new keywords), not just for namespace.
 *)
and using_kind =
  (* To bring a name in scope, =~ ImportFrom *)
  | UsingName of name
  (* =~ ImportAll *)
  | UsingNamespace of tok (*'namespace'*) * a_ident_name
  (* equivalent to a TypedefDecl, but
   * 'using PF = void ( * )(double);' is clearer than old C style
   * 'typedef void ( * PFD)(double);'
   * tsonly: type_ is usually just a name *)
  | UsingAlias of ident * tok (*'='*) * type_

(*****************************************************************************)
(* Cpp *)
(*****************************************************************************)
(* ------------------------------------------------------------------------- *)
(* cppext: #define and #include body *)
(* ------------------------------------------------------------------------- *)

(* all except ifdefs which are treated separately *)
and cpp_directive =
  | Define of tok (* #define*) * ident * define_kind * define_val
  (* tsonly: in pfff the first tok contains everything actually *)
  | Include of tok (* #include *) * include_kind
  (* other stuff *)
  | Undef of ident (* #undef xxx *)
  (* e.g., #line *)
  | PragmaAndCo of tok

and define_kind =
  | DefineVar
  (* tsonly: string can be special "..." *)
  | DefineMacro of ident list paren

and define_val =
  (* pfffonly *)
  | DefineExpr of expr
  | DefineStmt of stmt
  | DefineType of type_
  | DefineFunction of func_definition
  | DefineInit of initialiser (* in practice only { } with possible ',' *)
  (* do ... while(0) *)
  | DefineDoWhileZero of tok * stmt * tok * tok paren
  | DefinePrintWrapper of tok (* if *) * expr paren * name
  | DefineEmpty (* ?? dead? DefineText of string wrap *)
  | DefineTodo of todo_category

and include_kind =
  (* the string will not contain the enclosing '""' *)
  | IncLocal (* ex: "foo.h" *) of string wrap
  (* the string _will_ contain the enclosing '<>' *)
  | IncSystem (* ex: <sys.h> *) of string wrap
  | IncOther of a_cppExpr (* ex: SYSTEM_H, foo("x") *)

(* this is restricted to simple expressions like a && b *)
and a_cppExpr = expr

(* ------------------------------------------------------------------------- *)
(* cppext: #ifdefs *)
(* ------------------------------------------------------------------------- *)
and 'a sequencable =
  | X of 'a
  (* cppext: *)
  | CppDirective of cpp_directive
  | CppIfdef of ifdef_directive (* * 'a list *)
  | MacroDecl of specifier list * ident * argument list paren * sc
  | MacroVar of ident * sc

(* less: 'a ifdefed = 'a list wrap (* ifdef elsif else endif *) *)
and ifdef_directive =
  | Ifdef of tok (* todo? of string? *)
  (* TODO: IfIf of formula_cpp ? *)
  (* TODO: Ifndef *)
  | IfdefElse of tok
  | IfdefElseif of tok
  | IfdefEndif of tok
    (* less:
     * set in Parsing_hacks.set_ifdef_parenthize_info. It internally use
     * a global so it means if you parse the same file twice you may get
     * different id. I try now to avoid this pb by resetting it each
     * time I parse a file.
     *
     *   and matching_tag =
     *     IfdefTag of (int (* tag *) * int (* total with this tag *))
     *)
[@@deriving show { with_path = false }]

(*****************************************************************************)
(* Toplevel *)
(*****************************************************************************)

(* should be just 'decl sequencable', but again tree-sitter-cpp is
 * more general and accept also statements *)
type toplevel = stmt_or_decl sequencable [@@deriving show]

(* Finally! *)
type program = toplevel list [@@deriving show]

(*****************************************************************************)
(* Any *)
(*****************************************************************************)
type any =
  (* for semgrep *)
  | Expr of expr
  | Stmt of stmt
  | Stmts of stmt list
  | Toplevel of toplevel
  | Toplevels of toplevel list
  | Program of program
  | Cpp of cpp_directive
  | Type of type_
  | Name of name
  | OneDecl of onedecl
  | Init of initialiser
  | ClassMember of class_member
  | Constant of constant
  | Argument of argument
  | Parameter of parameter
  | Body of compound
  | Info of tok
  | InfoList of tok list
[@@deriving show { with_path = false }]
(* with tarzan *)

(*****************************************************************************)
(* Extra types, used just during parsing *)
(*****************************************************************************)
(* Take the left part of the type and build around it with the right part
 * to return a final type. For example in int[2], the
 * left part will be int and the right part [2] and the final
 * type will be int[2].
 *)
type abstract_declarator = type_ -> type_
[@@deriving show { with_path = false }]
(* with tarzan *)

(* A couple with a name and an abstract_declarator.
 * Note that with 'int* f(int)' we must return Func(Pointer int,int) and not
 * Pointer (Func(int,int)).
 *)
type declarator = { dn : declarator_name; dt : abstract_declarator }

and declarator_name =
  | DN of name
  (* c++17: structured binding, [n1, n2, n3] = expr,
   * at least one ident in it.
   *)
  | DNStructuredBinding of (ident * ident list) bracket
[@@deriving show { with_path = false }]
(* with tarzan *)

(*****************************************************************************)
(* Some constructors *)
(*****************************************************************************)
let nQ = []
let noQscope = []

(*****************************************************************************)
(* Wrappers *)
(*****************************************************************************)
let unwrap x = fst x
let unparen (_, x, _) = x
let unwrap_typeC (_qu, typeC) = typeC
let name_of_id (id : ident) : name = (None, [], IdIdent id)
let expr_of_id id = N (name_of_id id)
let expr_to_arg e = Arg e

(* often used for fake return type for constructor *)
let tvoid ii = (nQ, TPrimitive (TVoid, ii))

let get_original_token_location = function
  | Tok.OriginTok pi -> pi
  | Tok.ExpandedTok (pi, _) -> pi
  | Tok.FakeTokStr (_, _) -> raise (Tok.NoTokenLocation "FakeTokStr")
  | Tok.Ab -> raise (Tok.NoTokenLocation "Ab")

(* When want add some info in AST that does not correspond to
 * an existing C element.
 * old: when don't want 'synchronize' on it in unparse_c.ml
 * (now have other mark for tha matter).
 * used by parsing hacks
 *)
let make_expanded ii =
  (* TODO? use Pos.fake_pos? *)
  let no_virt_loc =
    ( { Tok.str = ""; pos = { bytepos = 0; line = 0; column = 0; file = "" } },
      -1 )
  in
  Tok.ExpandedTok (get_original_token_location ii, no_virt_loc)

let make_param ?(p_name = None) ?(p_specs = []) ?(p_val = None) t =
  { p_name; p_type = t; p_specs; p_val }

(* used by parsing hacks *)
let rewrap_pinfo pi _ii = pi

(* used while migrating the use of 'string' to 'name' in check_variables *)
let (string_of_name_tmp : name -> string) =
 fun name ->
  let _opt, _qu, id = name in
  match id with
  | IdIdent (s, _) -> s
  | _ -> failwith "TODO:string_of_name_tmp"

(* TODO: delete, used in highlight_cpp *)
let (ii_of_id_name : name -> tok list) =
 fun name ->
  let _opt, _qu, id = name in
  let rec ident_or_op id =
    match id with
    | IdIdent (_s, ii) -> [ ii ]
    | IdOperator (_, (_op, ii)) -> [ ii ]
    | IdConverter (_tok, _ft) -> failwith "ii_of_id_name: IdConverter"
    | IdDestructor (tok, (_s, ii)) -> [ tok; ii ]
    | IdTemplated (x, _args) -> ident_or_op x
  in
  ident_or_op id

let iis_of_dname = function
  | DN n -> ii_of_id_name n
  | DNStructuredBinding (l, (x, xs), r) ->
      [ l ] @ (x :: xs |> List.map snd) @ [ r ]

let (ii_of_name : name -> tok) =
 fun name ->
  let _opt, _qu, id = name in
  let rec ident_or_op id =
    match id with
    | IdIdent (_s, ii) -> ii
    | IdOperator (_, (_op, ii)) -> ii
    | IdConverter (tok, _ft) -> tok
    | IdDestructor (tok, (_s, _ii)) -> tok
    | IdTemplated (x, _args) -> ident_or_op x
  in
  ident_or_op id

let ii_of_dname = function
  | DN n -> ii_of_name n
  | DNStructuredBinding (l, _xs, _r) -> l
