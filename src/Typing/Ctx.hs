{-# LANGUAGE FlexibleContexts #-}
module Typing.Ctx
  ( Ctx()
  , defaultCtx
  , addType
  , getType
  , addValueType
  , getValueType
  , addInstance
  , getInstances
  ) where

import Typing.State
import Typing.Substitution
import Typing.TypeError
import Typing.Types hiding (list)

import qualified Typing.Types as Types (list)

data Ctx = Ctx { types :: [(String, Type)]
               , values :: [(String, Type)]
               , instances :: [(String, [Type])]
               }

getType :: String -> Ctx -> Tc Type
getType n ctx =
  case lookup n (types ctx) of
    Nothing -> throwError (UnknownType $ show n)
    Just t -> instantiate t

getValueType :: String -> Ctx -> Tc Type
getValueType n ctx =
  case lookup n (values ctx) of
    Nothing -> throwError (UnknownVariable n)
    Just t -> instantiate t

addType :: Ctx -> (String, Type) -> Ctx
addType ctx (n, ty) = ctx { types = (n, ty) : types ctx }

addValueType :: Ctx -> (String, Type) -> Ctx
addValueType ctx (n, ty) = ctx { values = (n, ty) : values ctx }

getInstances :: String -> Ctx -> Tc [Type]
getInstances n ctx =
  case lookup n (instances ctx) of
    Nothing -> return []
    Just insts -> return insts

addInstance :: Ctx -> (String, Type) -> Tc Ctx
addInstance ctx (n, ty) = do
  insts <- getInstances n ctx
  return $ ctx { instances = update n (ty : insts) (instances ctx) }
    where
      update key value [] = [(key, value)]
      update key value ((k,_):rest) | k == key = (key, value) : rest
      update key value (x:xs) = x : update key value xs

defaultCtx :: Ctx
defaultCtx =
  Ctx { types = [ ("Int", int)
                , ("Float", float)
                , ("Char", char)
                , ("String", string)
                , ("Void", void)
                , ("List", forall [T] $ list T)
                , ("Bool", bool)
                ]
      , values = [ ("int_print", [int] ~> void)
                 , ("int_add", [int, int] ~> int)
                 , ("int_sub", [int, int] ~> int)
                 , ("int_mul", [int, int] ~> int)
                 , ("int_div", [int, int] ~> int)
                 , ("True", bool)
                 , ("False", bool)
                 , ("Nil", forall [T] $ list T)
                 , ("Cons", forall [T] $ [var T, list T] ~> list T)
                 ]
      , instances = []
      }

-- HELPERS

list :: FakeVar -> Type
list ty = Types.list (var ty)

forall :: [FakeVar] -> Type -> Type
forall vs (Fun [] params args) =
  let vs' = map (flip (,) [] . tyvar) vs
   in Fun vs' params args

forall vs ty =
  TyAbs (map tyvar vs) ty

var :: FakeVar -> Type
var name = Var (tyvar name) []
