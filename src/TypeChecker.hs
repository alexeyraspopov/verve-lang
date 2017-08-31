{-# LANGUAGE NamedFieldPuns #-}

module TypeChecker
  ( infer
  , inferStmt
  , TypeError
  ) where

import Absyn
import Ctx hiding (getType, getValueType)
import Error
import TypeError
import Types
import qualified Ctx (getType, getValueType)

import Control.Monad (foldM, when, zipWithM, zipWithM_)
import Control.Monad.State (StateT, evalStateT, get, put)
import Control.Monad.Except (Except, runExcept, throwError)
import Data.Foldable (foldrM)
import Data.List (union, groupBy, intersect, sortBy)
import Data.Maybe (fromJust)

import qualified Data.List ((\\))

type Infer a = (StateT InferState (Except TypeError) a)

data InferState = InferState { uid :: Int }

(<:!) :: Type -> Type -> Infer ()
actualTy <:! expectedTy =
  when (not $ actualTy <: expectedTy) (throwError $ TypeError expectedTy actualTy)

resolveId :: Ctx -> Id UnresolvedType -> Infer (Id Type)
resolveId ctx (n, ty) = (,) n  <$> resolveType ctx ty

resolveType :: Ctx -> UnresolvedType -> Infer Type
resolveType ctx (UTName v) =
  getType v ctx
resolveType ctx (UTArrow params ret) = do
  params' <- mapM (resolveType ctx) params
  ret' <- resolveType ctx ret
  return $ Fun [] params' ret'
resolveType ctx (UTRecord fieldsTy) = do
  fieldsTy' <- mapM (resolveId ctx) fieldsTy
  return $ Rec fieldsTy'
resolveType ctx (UTApp t1 t2) = do
  t1' <- resolveType ctx t1
  t2' <- mapM (resolveType ctx) t2
  case t1' of
    -- TODO: this doesn't seem right
    TyAbs params ty ->
      return $ subst (zip params t2') ty
    _ -> return $ TyApp t1' t2'
resolveType _ UTVoid = return void
resolveType _ UTPlaceholder = undefined

resolveGenerics :: Ctx -> [(Name, [UnresolvedType])] -> Infer [(Name, [Type])]
resolveGenerics ctx gen =
  mapM aux gen
    where
      aux (name, bounds) = do
        bounds' <- mapM (resolveType ctx) bounds
        return (name, bounds')

instantiate :: Type -> Infer Type
instantiate (TyAbs gen ty) = do
  gen' <- mapM fresh gen
  let s = zip gen (map (flip Var []) gen')
  return $ TyAbs gen' (subst s ty)
instantiate (Fun gen params ret) = do
  gen' <- mapM freshBound gen
  let s = zip (map fst gen) (map (uncurry Var) gen')
  return $ Fun gen' (map (subst s) params) (subst s ret)
instantiate ty = return ty

fresh :: Var -> Infer Var
fresh var = do
  s <- get
  put s{uid = uid s + 1}
  return $ unsafeFreshVar var (uid s)

freshBound :: (Var, [Type]) -> Infer (Var, [Type])
freshBound (var, bounds) = do
  var' <- fresh var
  return (var', bounds)

getType :: Name -> Ctx -> Infer Type
getType n ctx = Ctx.getType n ctx >>= instantiate

getValueType :: Name -> Ctx -> Infer Type
getValueType n ctx = Ctx.getValueType n ctx >>= instantiate

addGenerics :: Ctx -> [(Name, [Type])] -> Infer (Ctx, [(Var, [Type])])
addGenerics ctx generics =
  foldM aux (ctx, []) generics
    where
      aux (ctx, vars) (g, bounds) = do
        g' <- fresh (var g)
        return (addTypeVar ctx (var g, Var g' bounds), vars ++ [(g', bounds)])

defaultBounds :: [a] -> [(a, [b])]
defaultBounds = map (flip (,) [])

initInfer :: InferState
initInfer = InferState { uid = 0 }

runInfer :: Infer a -> (a -> b) -> Result b
runInfer m f =
  case runExcept $ evalStateT m initInfer of
    Left err -> Left (Error err)
    Right v -> Right (f v)


infer :: Module Name UnresolvedType -> Result (Module (Id Type) Type, Type)
infer mod =
  runInfer
    (i_stmts defaultCtx (stmts mod))
    (\(stmts, ty) -> (Module stmts, ty))

inferStmt :: Ctx -> Stmt Name UnresolvedType -> Result (Ctx, Stmt (Id Type) Type, Type)
inferStmt ctx stmt =
  runInfer (i_stmt ctx stmt) id

i_stmts :: Ctx -> [Stmt Name UnresolvedType ] -> Infer ([Stmt (Id Type) Type], Type)
i_stmts ctx stmts = do
  (_, stmts', ty) <- foldM aux (ctx, [], void) stmts
  return (reverse stmts', ty)
    where
      aux :: (Ctx, [Stmt (Id Type) Type], Type) -> Stmt Name  UnresolvedType -> Infer (Ctx, [Stmt (Id Type) Type], Type)
      aux (ctx, stmts, _) stmt = do
        (ctx', stmt', ty) <- i_stmt ctx stmt
        return (ctx', stmt':stmts, ty)

i_stmt :: Ctx -> Stmt Name UnresolvedType -> Infer (Ctx, Stmt (Id Type) Type, Type)
i_stmt ctx (Expr expr) = do
  (expr', ty) <- i_expr ctx expr
  return (ctx, Expr expr', ty)

i_stmt ctx (FnStmt fn) = do
  (fn', ty) <- i_fn ctx fn
  return (addValueType ctx (name fn, ty), FnStmt fn', ty)

i_stmt ctx (Enum name generics ctors) = do
  (ctx', generics') <- addGenerics ctx (defaultBounds generics)
  let mkEnumTy ty = case (ty, generics') of
                (Nothing, []) -> Con name
                (Just t, [])  -> Fun [] t (Con name)
                (Nothing, _)  -> TyAbs (map fst generics') (TyApp (Con name) (map (uncurry Var) generics'))
                (Just t, _)   -> Fun generics' t (TyApp (Con name) (map (uncurry Var) generics'))
  let enumTy = mkEnumTy Nothing
  let ctx'' = addType ctx' (name, enumTy)
  (ctx''', ctors') <- foldrM (i_ctor mkEnumTy) (ctx'', []) ctors
  return (ctx''', (Enum (name, enumTy) generics ctors'), Type)

i_stmt ctx (Operator opAssoc opPrec opGenerics opLhs opName opRhs opRetType opBody) = do
  opGenerics' <- resolveGenerics ctx opGenerics
  (ctx', opGenericVars) <- addGenerics ctx opGenerics'
  opLhs' <- resolveId ctx' opLhs
  opRhs' <- resolveId ctx' opRhs
  opRetType' <- resolveType ctx' opRetType
  let ctx'' = addValueType (addValueType ctx' opLhs') opRhs'
  (opBody', bodyTy) <- i_stmts ctx'' opBody
  bodyTy <:! opRetType'
  let ty = Fun opGenericVars [snd opLhs', snd opRhs'] opRetType'
  let op' = Operator { opAssoc
                     , opPrec
                     , opGenerics = opGenerics'
                     , opLhs = opLhs'
                     , opName = (opName, ty)
                     , opRhs = opRhs'
                     , opRetType = opRetType'
                     , opBody = opBody' }
  return (addValueType ctx (opName, ty), op', ty)

i_stmt ctx (Let var expr) = do
  (expr', exprTy) <- i_expr ctx expr
  let ctx' = addValueType ctx (var, exprTy)
  let let' = Let (var, exprTy) expr'
  return (ctx', let', void)

i_stmt ctx (Class name vars methods) = do
  vars' <- mapM (resolveId ctx) vars
  let classTy = Cls name vars'
  let ctorTy = [Rec vars'] ~> classTy
  let ctx' = addType ctx (name, classTy)
  let ctx'' = addValueType ctx' (name, ctorTy)

  (ctx''', methods') <- foldM (i_method classTy) (ctx'', []) methods
  let class' = Class (name, classTy) vars' methods'
  return (ctx''', class', Type)

i_stmt ctx (Interface name param methods) = do
  (ctx', [(param', [])]) <- addGenerics ctx [(param, [])]
  (methods', methodsTy) <- unzip <$> mapM (i_fnDecl ctx') methods
  let ty = Intf name param' methodsTy
  let intf = Interface (name, ty) param methods'
  let ctx' = foldl (aux ty param') ctx methodsTy
  return (addType ctx' (name, ty), intf, ty)
    where
      aux intf param ctx (name, Fun gen params retType) =
        let ty = Fun ((param, [intf]) : gen) params retType
         in addValueType ctx (name, ty)
      aux _ _ _ _ = undefined

i_stmt ctx (Implementation implName ty methods) = do
  Intf _ param intfMethods <- getType implName ctx
  ty' <- resolveType ctx ty
  -- TODO: proper error in intf is not an Intf
  (methods', methodsTy) <- unzip <$> mapM (i_fn ctx) methods
  let substs = [(param, ty')]
  checkCompleteInterface substs intfMethods (zip (map name methods) methodsTy)
  checkExtraneousMethods intfMethods (zip (map name methods) methodsTy)
  ctx' <- addInstance ctx (implName, ty')
  let impl = Implementation (implName, void) ty' methods'
  return (ctx', impl, void)

checkCompleteInterface :: [(Var, Type)] -> [(Name, Type)] -> [(Name, Type)] -> Infer ()
checkCompleteInterface substs intf impl = do
  mapM_ aux intf
  where
    aux :: (Name, Type) -> Infer ()
    aux (methodName, methodTy) =
      case lookup methodName impl of
        Nothing -> throwError $ MissingImplementation methodName
        Just ty -> ty <:! (subst substs methodTy)

checkExtraneousMethods :: [(Name, Type)] -> [(Name, Type)] -> Infer ()
checkExtraneousMethods intf impl = do
  mapM_ aux impl
  where
    aux :: (Name, Type) -> Infer ()
    aux (methodName, _) =
      case lookup methodName intf of
        Nothing -> throwError $ ExtraneousImplementation methodName
        Just _ -> return ()

i_fnDecl :: Ctx -> FunctionDecl Name UnresolvedType -> Infer (FunctionDecl (Id Type) Type, (Name, Type))
i_fnDecl ctx (FunctionDecl name gen params retType) = do
  gen' <- resolveGenerics ctx gen
  (ctx', genVars) <- addGenerics ctx gen'
  (ty, params', retType') <- fnTy ctx' (genVars, params, retType)
  let fnDecl = FunctionDecl (name, ty) gen' params' retType'
  return (fnDecl, (name, ty))

fnTy :: Ctx -> ([(Var, [Type])], [(Name, UnresolvedType)], UnresolvedType) -> Infer (Type, [(Name, Type)], Type)
fnTy ctx (generics, params, retType) = do
  tyArgs <- mapM (resolveId ctx) params
  retType' <- resolveType ctx retType
  let tyArgs' = if null tyArgs
      then [void]
      else map snd tyArgs
  let ty = Fun generics tyArgs' retType'
  return (ty, tyArgs, retType')

i_method :: Type -> (Ctx, [Function (Id Type) Type]) -> Function Name UnresolvedType -> Infer (Ctx, [Function (Id Type) Type])
i_method classTy (ctx, fns) fn = do
  let ctx' = addType ctx ("Self", classTy)
  let fn' = fn { params = ("self", UTName "Self") : params fn }
  (fn'', fnTy) <- i_fn ctx' fn'
  return (addValueType ctx (name fn, fnTy), fn'' : fns)

i_ctor :: (Maybe [Type] -> Type) -> DataCtor Name UnresolvedType -> (Ctx, [DataCtor (Id Type) Type]) -> Infer (Ctx, [DataCtor (Id Type) Type])
i_ctor mkEnumTy (name, types) (ctx, ctors) = do
  types' <- sequence (types >>= return . mapM (resolveType ctx))
  let ty = mkEnumTy types'
  return (addValueType ctx (name, ty), ((name, ty), types'):ctors)

i_fn :: Ctx -> Function Name UnresolvedType -> Infer (Function (Id Type) Type, Type)
i_fn ctx fn = do
  gen' <- resolveGenerics ctx $ generics fn
  (ctx', genericVars) <- addGenerics ctx gen'
  (ty, tyArgs, retType') <- fnTy ctx' (genericVars, params fn, retType fn)
  let ctx'' = addValueType ctx' (name fn, ty)
  let ctx''' = foldl addValueType ctx'' tyArgs
  (body', bodyTy) <- i_stmts ctx''' (body fn)
  bodyTy <:! retType'
  let fn' = fn { name = (name fn, ty)
               , generics = gen'
               , params = tyArgs
               , retType = retType'
               , body = body'
               }
  return (fn', ty)

i_expr :: Ctx -> Expr Name UnresolvedType -> Infer (Expr (Id Type) Type, Type)
i_expr _ (Literal lit) = return (Literal lit, i_lit lit)

i_expr ctx (Ident i) = do
  ty <- getValueType i ctx
  return (Ident (i, ty), ty)

i_expr _ VoidExpr = return (VoidExpr, void)

i_expr ctx (ParenthesizedExpr expr) = i_expr ctx expr

i_expr ctx (BinOp _ lhs op rhs) = do
  tyOp@(Fun _ _ retType) <- getValueType op ctx
  (lhs', lhsTy) <- i_expr ctx lhs
  (rhs', rhsTy) <- i_expr ctx rhs
  substs <- inferTyArgs [lhsTy, rhsTy] tyOp
  let tyOp' = subst substs tyOp
  return (BinOp (map snd substs) lhs' (op, tyOp') rhs', subst substs retType)

i_expr ctx (Match expr cases) = do
  (expr', ty) <- i_expr ctx expr
  (cases', casesTy) <- unzip <$> mapM (i_case ctx ty) cases
  let retTy = case casesTy of
                [] -> void
                x:xs -> foldl (\/) x xs
  return (Match expr' cases', retTy)
i_expr ctx (Call fn constraintArgs types []) = i_expr ctx (Call fn constraintArgs types [VoidExpr])
i_expr ctx (Call fn _ types args) = do
  (fn', tyFn) <- i_expr ctx fn
  (args', tyArgs) <- mapM (i_expr ctx) args >>= return . unzip
  types' <- mapM (resolveType ctx) types
  let tyFn' = normalizeFnType tyFn
  tyFn''@(Fun gen _ retType) <- adjustFnType tyArgs tyFn'
  substs <-
        case (tyFn'', types') of
          (Fun (_:_) _ _, []) ->
            inferTyArgs tyArgs tyFn''
          (Fun gen params _, _) -> do
            let s = zip (map fst gen) types'
            let params' = map (subst s) params
            zipWithM_ (<:!) tyArgs params'
            return s
          _ -> undefined
  let retType' = subst substs retType
  let typeArgs' = map (fromJust . flip lookup substs . fst) gen
  constraintArgs <- concat <$> mapM (aux ctx) (zip gen typeArgs')
  return (Call fn' constraintArgs typeArgs' args', retType')
    where
      aux ctx ((_, bounds), tyArg) = do
        mapM_ (boundsCheck ctx tyArg) bounds
        return $ map ((,) tyArg) bounds

i_expr ctx (Record fields) = do
  (exprs, types) <- mapM (i_expr ctx . snd) fields >>= return . unzip
  let labels = map fst fields
  let fieldsTy = zip labels types
  let recordTy = Rec fieldsTy
  let record = Record (zip fieldsTy exprs)
  return (record, recordTy)

i_expr ctx (FieldAccess expr _ field) = do
  (expr', ty) <- i_expr ctx expr
  let
      aux :: Type -> [(String, Type)] -> Infer (Expr (Id Type) Type, Type)
      aux ty r = case lookup field r of
                Nothing -> throwError $ UnknownField ty field
                Just t -> return (FieldAccess expr' ty (field, t), t)
  case ty of
    Rec r -> aux ty r
    Cls _ r -> aux ty r
    _ -> throwError . GenericError $ "Expected a record, but found value of type " ++ show ty

i_expr ctx (If ifCond ifBody elseBody) = do
  (ifCond', ty) <- i_expr ctx ifCond
  ty <:! bool
  (ifBody', ifTy) <- i_stmts ctx ifBody
  (elseBody', elseTy) <- i_stmts ctx elseBody
  return (If ifCond' ifBody' elseBody', ifTy \/ elseTy)

i_expr ctx (List items) = do
  (items', itemsTy) <- unzip <$> mapM (i_expr ctx) items
  let ty = case itemsTy of
             [] -> genericList
             x:xs -> list $ foldl (\/) x xs
  return (List items', ty)

boundsCheck :: Ctx -> Type -> Type -> Infer ()
boundsCheck _ v@(Var _ bounds) ty@(Intf name _ _) = do
  when (ty `notElem` bounds) (throwError $ MissingInstance name v)

boundsCheck ctx ty (Intf name _ _) = do
  instances <- getInstances name ctx
  when (ty `notElem` instances) (throwError $ MissingInstance name ty)

boundsCheck _ _ ty =
  throwError $ InterfaceExpected ty

normalizeFnType :: Type -> Type
normalizeFnType (Fun gen params (Fun [] params' retTy)) =
  normalizeFnType (Fun gen (params ++ params') retTy)
normalizeFnType ty = ty

adjustFnType :: [a] -> Type -> Infer Type
adjustFnType args fn@(Fun gen params retType) = do
  let lArgs = length args
  case compare lArgs (length params) of
    EQ -> return fn
    LT ->
      return $ Fun gen (take lArgs params) $ Fun [] (drop lArgs params) retType
    GT -> throwError ArityMismatch
adjustFnType _ ty = throwError . GenericError $ "Expected a function, found " ++ show ty

i_lit :: Literal -> Type
i_lit (Integer _) = int
i_lit (Float _) = float
i_lit (Char _) = char
i_lit (String _) = string

i_case :: Ctx -> Type -> Case Name UnresolvedType -> Infer (Case (Id Type) Type, Type)
i_case ctx ty (Case pattern caseBody) = do
  (pattern', ctx') <- c_pattern ctx ty pattern
  (caseBody', ty) <- i_stmts ctx' caseBody
  return (Case pattern' caseBody', ty)

c_pattern :: Ctx -> Type -> Pattern Name -> Infer (Pattern (Id Type), Ctx)
c_pattern ctx _ PatDefault = return (PatDefault, ctx)
c_pattern ctx ty (PatLiteral l) = do
  let litTy = i_lit l
  litTy <:! ty
  return (PatLiteral l, ctx)
c_pattern ctx ty (PatVar v) =
  let pat = PatVar (v, ty)
      ctx' = addValueType ctx (v, ty)
   in return (pat, ctx')
c_pattern ctx ty (PatCtor name vars) = do
  ctorTy <- getValueType name ctx
  let (fnTy, params, retTy) = case ctorTy of
                            fn@(Fun [] params retTy) -> (fn, params, retTy)
                            fn@(Fun gen params retTy) -> (fn, params, TyAbs (map fst gen) retTy)
                            t -> (Fun [] [] t, [], t)
  when (length vars /= length params) (throwError ArityMismatch)
  retTy <:! ty
  let substs = case (retTy, ty) of
                 (TyAbs gen _, TyApp _ args) -> zip gen args
                 _ -> []
  let params' = map (subst substs) params
  (vars', ctx') <- foldM aux ([], ctx) (zip params' vars)
  return (PatCtor (name, fnTy) vars', ctx')
    where
      aux (vars, ctx) (ty, var) = do
        (var', ctx') <- c_pattern ctx ty var
        return (var':vars, ctx')

-- Inference of type arguments for generic functions
inferTyArgs :: [Type] -> Type -> Infer [Substitution]
inferTyArgs tyArgs (Fun generics params retType) = do
  let initialCs = map (flip (Constraint Bot) Top . fst) generics
  d <- zipWithM (constraintGen [] (map fst generics)) tyArgs params
  let c = initialCs `meet` foldl meet [] d
  mapM (getSubst retType) c
inferTyArgs _ _ = throwError $ ArityMismatch

-- Variable Elimination

-- S ⇑V T
(//) :: [Var] -> Type -> Type

-- VU-Top
_ // Top = Top

-- VU-Bot
_ // Bot = Bot

-- VU-Con
_ // (Con x) = (Con x)

-- VU-Type
_ // Type = Type

v // var@(Var x _)
  -- VU-Var-1
  | x `elem` v = Top
  -- VU-Var-2
  | otherwise = var

-- VU-Fun
v // (Fun x s t) =
  let u = map ((\\) v) s in
  let r = v // t in
  Fun x u r

v // (Rec fields) =
  let fields' = map (\(k, t) -> (k, v // t)) fields
   in Rec fields'

v // (Cls name vars) =
  let vars' = map (\(k, t) -> (k, v // t)) vars
   in Cls name vars'

v // (TyAbs gen ty) =
  let v' = v Data.List.\\ gen
   in TyAbs gen (v' // ty)

v // (TyApp ty args) =
  TyApp (v // ty) (map ((//) v) args)

v // (Intf name param methods) =
  let v' = v Data.List.\\ [param]
      methods' = map (fmap $ (//) v') methods
   in Intf name param methods'

-- S ⇓V T
(\\) :: [Var] -> Type -> Type
-- VD-Top
_ \\ Top = Top

-- VD-Bot
_ \\ Bot = Bot
--
-- VD-Con
_ \\ (Con x) = (Con x)

-- VD-Type
_ \\ Type = Type

v \\ var@(Var x _)
  -- VD-Var-1
  | x `elem` v = Bot
  -- VD-Var-2
  | otherwise = var

-- VD-Fun
v \\ (Fun x s t) =
  let u = map ((//) v) s in
  let r = v \\ t in
  Fun x u r

v \\ (Rec fields) =
  let fields' = map (\(k, t) -> (k, v \\ t)) fields
   in Rec fields'

v \\ (Cls name vars) =
  let vars' = map (\(k, t) -> (k, v \\ t)) vars
   in Cls name vars'

v \\ (TyAbs gen ty) =
  let v' = v Data.List.\\ gen
   in TyAbs gen (v' \\ ty)

v \\ (TyApp ty args) =
  TyApp (v \\ ty) (map ((\\) v) args)

v \\ (Intf name param methods) =
  let v' = v Data.List.\\ [param]
      methods' = map (fmap $ (\\) v') methods
   in Intf name param methods'

-- Constraint Solving
data Constraint
  = Constraint Type Var Type
  deriving (Eq, Show)

constraintGen :: [Var] -> [Var] -> Type -> Type -> Infer [Constraint]

-- CG-Top
constraintGen _ _ _ Top = return []

-- CG-Bot
constraintGen _ _ Bot _ = return []

-- CG-Upper
constraintGen v x (Var y _) s | y `elem` x && fv s `intersect` x == [] =
  let t = v \\ s
   in return [Constraint Bot y t]

-- CG-Lower
constraintGen v x s (Var y _) | y `elem` x && fv s `intersect` x == [] =
  let t = v // s
   in return [Constraint t y Top]

-- CG-Refl
constraintGen _v _x t1 t2 | t1 <: t2 = return []

-- CG-Fun
constraintGen v x (Fun y r s) (Fun y' t u)
  | y == y' && map fst y `intersect` (v `union` x) == [] = do
    c <- zipWithM (constraintGen (v `union` map fst y) x) t r
    d <- constraintGen (v `union` map fst y) x s u
    return $ foldl meet [] c `meet` d

constraintGen v x (TyApp t11 t12) (TyApp t21 t22) = do
  cTy <- constraintGen v x t11 t21
  cArgs <- zipWithM (constraintGen v x) t12 t22
  return $ foldl meet [] cArgs `meet` cTy

constraintGen _v _x actual expected =
  throwError $ TypeError expected actual

-- Least Upper Bound
(\/) :: Type -> Type -> Type

s \/ t | s <: t = t
s \/ t | t <: s = s
(Fun x v p) \/ (Fun x' w q) | x == x' =
  Fun x (zipWith (/\) v w) (p \/ q)
(Rec f1) \/ (Rec f2) =
  let fields = (fst <$> f1) `intersect` (fst <$> f2)
   in Rec $ map (\f -> (f, fromJust (lookup f f1) \/ fromJust (lookup f f2))) fields
_ \/ _ = Top

-- Greatest Lower Bound
(/\) :: Type -> Type -> Type
s /\ t | s <: t = s
s /\ t | t <: s = t
(Fun x v p) /\ (Fun x' w q) | x == x' =
  Fun x (zipWith (\/) v w) (p /\ q)
(Rec f1) /\ (Rec f2) =
  let fields = (fst <$> f1) `union` (fst <$> f2)
   in Rec $ map (\f -> (f, maybe Top id (lookup f f1) /\ maybe Top id (lookup f f2))) fields
_ /\ _ = Bot

-- The meet of two X/V-constraints C and D, written C /\ D, is defined as follows:
meet :: [Constraint] -> [Constraint] -> [Constraint]
meet c [] = c
meet [] d = d
meet c d =
  map merge cs
    where
      cs = groupBy prj sorted
      sorted = sortBy (\(Constraint _ t _) (Constraint _ u _) -> compare t u) (c `union` d)
      prj (Constraint _ t _) (Constraint _ u _) = t == u
      merge [] = undefined
      merge (c:cs) = foldl mergeC c cs
      mergeC (Constraint s x t) (Constraint u _ v) =
        Constraint (s \/ u) x (t /\ v)

--- Calculate Variance
data Variance
  = Bivariant
  | Covariant
  | Contravariant
  | Invariant
  deriving (Eq, Show)

variance :: Var -> Type -> Variance
variance _ Top = Bivariant
variance _ Bot = Bivariant
variance _ (Con _) = Bivariant
variance _ Type = Bivariant
variance v (Var x _)
  | v == x = Covariant
  | otherwise = Bivariant
variance v (Fun x t r)
  | v `elem` map fst x = Bivariant
  | otherwise =
    let t' = map (invertVariance . variance v) t in
    (foldl joinVariance Bivariant t') `joinVariance` variance v r
variance v (Rec fields) =
  let vars = map (variance v . snd) fields
   in foldl joinVariance Bivariant vars
variance v (Cls _ vars) =
  let vars' = map (variance v . snd) vars
   in foldl joinVariance Bivariant vars'
variance v (TyAbs gen ty)
  | v `elem` gen = Bivariant
  | otherwise = variance v ty
variance v (TyApp ty args) =
  let vars = map (variance v) args
   in foldl joinVariance (variance v ty) vars
variance v (Intf _ param methods)
  | v == param = Bivariant
  | otherwise =
    let methods' = map (variance v . snd) methods
     in foldl joinVariance Bivariant methods'

invertVariance :: Variance -> Variance
invertVariance Covariant = Contravariant
invertVariance Contravariant = Covariant
invertVariance c = c

joinVariance :: Variance -> Variance -> Variance
joinVariance Bivariant d = d
joinVariance c Bivariant = c
joinVariance c d | c == d = c
joinVariance _ _ = Invariant

-- Create Substitution
type Substitution = (Var, Type)

getSubst :: Type -> Constraint -> Infer Substitution
getSubst r (Constraint s x t) =
  case variance x r of
    Bivariant -> return (x, s)
    Covariant -> return (x, s)
    Contravariant -> return (x, t)
    Invariant | s == t -> return (x, s)
    _ -> throwError InferenceFailure
