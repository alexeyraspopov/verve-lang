module Core.Desugar
  ( desugar
  , desugarStmt
  ) where

import Absyn.Typed
import Typing.Types
import qualified Core.Absyn as CA

import Data.Bifunctor (second)

desugar :: Module -> CA.Expr
desugar = d_stmts . stmts

desugarStmt :: Stmt -> CA.Expr
desugarStmt stmt = d_stmts [stmt]

d_stmts :: [Stmt] -> CA.Expr
d_stmts [] = CA.Void
-- terminators
d_stmts ([Expr e]) =
  d_expr e
d_stmts ([Decl (FnStmt fn)]) =
  let fn' = d_fn fn
   in CA.Let [(name fn, fn')] (CA.Var $ name fn)
d_stmts ([Decl (Let var expr)]) =
  CA.Let [(var, d_expr expr)] (CA.Var var)

d_stmts (Decl decl : ss) =
  CA.Let (d_decl decl) (d_stmts ss)
d_stmts (Expr e:ss) =
  CA.Let [(ignore void, d_expr e)] (d_stmts ss)

d_decl :: Decl -> [CA.Bind]
d_decl (Let var expr) =
  [(var, d_expr expr)]
d_decl (FnStmt fn) =
  [(name fn, d_fn fn)]
d_decl (Enum name _ _) =
  [(ignore Type, CA.Var name)]
d_decl (TypeAlias { aliasName, aliasType }) =
  [((aliasName, Type), CA.Type aliasType)]
d_decl (Operator _ _ opGenerics opLhs opName opRhs opRetType opBody) =
  let fn = d_fn (Function { name = opName
                          , generics = opGenerics
                          , params = [opLhs, opRhs]
                          , retType = opRetType
                          , body = opBody
                          })
   in [(opName, fn)]
d_decl (Class _ _ methods) =
  map (\fn -> (name fn, d_fn fn)) methods

d_decl (Interface _ _ methods) =
  map d_intfMethod methods

d_decl (Implementation (name, _) generics ty methods) =
  let dict = CA.Record (map d_implItem methods)
      dictName = ("#" ++ name ++ print ty, void)
      dictLam = foldr CA.Lam dict (mkConstraints generics)
   in [(dictName, dictLam)]
  where
    print (TyApp ty _) = print ty
    print ty = show ty

d_fn :: Function -> CA.Expr
d_fn fn@(Function { params=[] }) =
  d_fn (fn { params = [ignore void] })

d_fn fn =
  let fn' = foldr CA.Lam (d_stmts $ body fn) (map (uncurry (,)) $ params fn)
   in foldr CA.Lam fn' (mkConstraints $ generics fn)

mkConstraints :: Generics -> [Id]
mkConstraints gen =
  concatMap aux gen
  where
    aux (varName, bounds) =
      map (\bound -> ("#" ++ show bound ++ varName, void)) bounds ++ [(varName, Type)]

mk_var :: String -> CA.Expr
mk_var v = CA.Var (v, void)

d_intfMethod :: InterfaceItem -> CA.Bind
d_intfMethod (IntfVar name@(s_name,  _)) =
  let select = CA.App (mk_var "#fieldAccess") (CA.Lit (String s_name))
      select' = CA.App select (mk_var "#dict")
   in (name, CA.Lam ("#dict", void) (CA.Lam (ignore Type) select'))

d_intfMethod (IntfOperator { intfOpName = name@(s_name,  _) }) =
  let select = CA.App (mk_var "#fieldAccess") (CA.Lit (String s_name))
      select' = CA.App select (mk_var "#dict")
   in (name, CA.Lam ("#dict", void) (CA.Lam (ignore Type) select'))

d_implItem :: ImplementationItem -> CA.Bind
d_implItem (ImplVar (name, expr)) =
  (name, d_expr expr)

d_implItem fn@(ImplFunction {}) =
  let fn' = foldr CA.Lam (d_stmts $ implBody fn) (map (flip (,) void) $ implParams fn)
   in (implName fn, fn')

d_implItem op@(ImplOperator {}) =
  let op' = CA.Lam (implOpLhs op, void) (CA.Lam (implOpRhs op, void) (d_stmts $ implOpBody op))
   in (implOpName op, op')

data Constraint
  = CHole
  | CType Type
  | CDict Type Intf
  | CApp Constraint [Constraint]

d_expr :: Expr -> CA.Expr
d_expr VoidExpr = CA.Void
d_expr (TypeCall callee constraints) =
  let (constraints', constraintHoles) = computeConstraints constraints
      app = foldl CA.App (d_expr callee) constraints'
   in foldl (flip CA.Lam) app constraintHoles

d_expr (Literal l) = CA.Lit l
d_expr (Ident ids ty) = CA.Var (last ids, ty)
d_expr (ParenthesizedExpr expr) = d_expr expr
d_expr (Call callee constraints types []) = d_expr (Call callee constraints types [VoidExpr])
d_expr (BinOp constrArgs tyArgs lhs (name, ty) rhs) =
  d_expr (Call (Ident [name] ty) constrArgs tyArgs [lhs, rhs])

d_expr (Call callee constraints _ args) =
  let (constraints', constraintHoles) = computeConstraints constraints
      app = foldl CA.App (d_expr callee) constraints'
      app' = foldl mkApp app args
   in foldl (flip CA.Lam) app' constraintHoles
    where
      mkApp :: CA.Expr -> Expr -> CA.Expr
      mkApp callee arg =
        CA.App callee (d_expr arg)

d_expr (Match expr cases) = CA.Match (d_expr expr) (map d_case cases)

d_expr (Record fields) =
  let fields' = map (\(a, b) -> (a, d_expr b)) fields
   in CA.Record fields'

d_expr (FieldAccess expr ty (field, _)) =
  let dexpr = (d_expr expr)
      expr' =
        case ty of
          Cls _ -> CA.App (CA.Var ("#unwrapClass", void)) dexpr
          Rec _ -> dexpr
          _ -> undefined
   in CA.App
    (CA.App (CA.Var ("#fieldAccess", void)) (CA.Lit $ String field))
    expr'

d_expr (If ifCond ifBody elseBody) =
  CA.Match (d_expr ifCond) [ (CA.PatCtor ("True", bool) [], d_stmts ifBody)
                           , (CA.PatCtor ("False", bool) [], d_stmts elseBody)
                           ]

d_expr (List ty items) =
  aux items
    where
      aux [] = nil
      aux (x:xs) = cons (d_expr x) (aux xs)
      nil = CA.Var ("Nil", void)
      cons head tail = CA.App (CA.App (CA.App (CA.Var ("Cons", void)) (CA.Type ty)) head) tail

d_expr (FnExpr fn) =
  d_fn fn

d_expr (Negate constrArgs expr) =
  let (constraints', _) = computeConstraints constrArgs
      negate = (CA.Var ("Std.negate", void))
      app = foldl CA.App negate constraints'
      expr' = d_expr expr
   in CA.App app expr'

computeConstraints :: [ConstraintArg] -> ([CA.Expr], [Id])
computeConstraints cs = foldl aux ([], []) $ concatMap mkConstraint cs
  where
    aux (args, holes) CHole =
      let holeName = "#hole" ++ show (length holes)
       in (args ++ [mk_var holeName], (holeName, void) : holes)

    aux (args, holes) (CType typeArg) =
      (args ++ [CA.Type typeArg], holes)

    aux (args, holes) (CDict typeArg typeBound) =
      let constr = mk_var ("#" ++ show typeBound ++ show typeArg)
       in (args ++ [constr], holes)

    aux (args, holes) (CApp typeArg nestedArgs) =
      let (nestedArgs', holes') = foldl aux ([], holes) nestedArgs
       in case aux ([], holes') typeArg of
            ([typeArg'], holes'') ->
              let app = foldl CA.App typeArg' nestedArgs'
               in (args ++ [app], holes'')
            _ -> undefined

    mkConstraint :: ConstraintArg -> [Constraint]
    mkConstraint (CAType typeArg) =
      [mkTypeArg typeArg]

    mkConstraint (CABound typeArg typeBound) =
      [mkTypeBound (typeArg, typeBound), mkTypeArg typeArg]

    mkConstraint (CAPoly typeArg typeBound args) =
      let typeBound' = mkTypeBound (typeArg, typeBound)
          args' = concatMap mkConstraint args
       in [CApp typeBound' args', mkTypeArg typeArg]

    mkTypeArg :: Type -> Constraint
    mkTypeArg t | isHole t = CHole
    mkTypeArg t = CType t

    mkTypeBound :: (Type, Intf) -> Constraint
    mkTypeBound (typeArg, _) | isHole typeArg = CHole
    mkTypeBound (typeArg, typeBound) = CDict typeArg typeBound

d_case :: Case -> CA.Case
d_case (Case pattern expr) = (d_pattern pattern, d_stmts expr)

d_pattern :: Pattern -> CA.Pattern
d_pattern PatDefault = CA.PatDefault
d_pattern (PatLiteral l) = CA.PatLiteral l
d_pattern (PatVar v) = CA.PatVar v

d_pattern (PatRecord fields) = CA.PatRecord $ map (second d_pattern) fields

d_pattern (PatList pats rest) =
  let init = case rest of
               NoRest -> CA.PatCtor ("Nil", void) []
               DiscardRest -> CA.PatDefault
               NamedRest n -> CA.PatVar n
      aux pat tail =
        let pat' = d_pattern pat
         in CA.PatCtor ("Cons", void) [tail, pat']
   in foldr aux init (reverse pats)

d_pattern (PatCtor name pats) = CA.PatCtor name (map d_pattern pats)

ignore :: Type -> Id
ignore ty = ("#ignore", ty)
