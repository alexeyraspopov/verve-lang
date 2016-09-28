module Generator (generate) where

import AST hiding (functions)
import Bytecode
import Opcode
import TypeChecker
import Data.Bits (shiftL, (.|.))

import Control.Monad.Reader (ReaderT, runReaderT)
import Control.Monad.State (State, state, get, put, evalState)
import Data.Bits (shiftL, (.|.))
import Data.List (elemIndex)

type BytecodeState = State Bytecode ()

initialState = Bytecode
  {
    text = [],
    strings = [],
    functions = []
  }

generate :: Program TcId -> Bytecode
generate program =
  evalState (generate_program program >> get) initialState

emit_opcode :: Opcode -> BytecodeState
emit_opcode op = do
  bc <- get
  put bc { text = (text bc) ++ [toInteger $ fromEnum op] }

write :: Integer -> BytecodeState
write value = do
  bc <- get
  put bc { text = (text bc) ++ [value] }

unique_string :: String -> BytecodeState
unique_string str = do
  bc <- get
  case elemIndex str (strings bc) of
    Just index -> write $ toInteger index
    Nothing -> let id = toInteger $ length (strings bc)
                in do {
                      put bc { strings = (strings bc) ++ [str] };
                      write id
                      }


decode_double :: Double -> Integer
decode_double double =
  let (significand, exponent) = decodeFloat double
   in (shiftL (toInteger exponent) 53) .|. significand

generate_program :: Program TcId -> BytecodeState
generate_program (Program _ decls) = do
  mapM_ generate_decl decls
  emit_opcode Op_exit

generate_decl :: TopDecl TcId -> BytecodeState
generate_decl (InterfaceDecl _) = return ()
generate_decl (ImplementationDecl _) = return ()
generate_decl (ExternDecl _) = return ()
generate_decl (TypeDecl _) = return ()
generate_decl (ExprDecl expr) = generate_expr expr

generate_expr :: Expr TcId -> BytecodeState
generate_expr (FunctionExpr fn) = generate_function fn

generate_expr (LiteralExpr lit) = generate_literal lit

generate_expr (Var (Loc _ (TcId name _))) = do
  emit_opcode Op_lookup
  unique_string name
  write 0 -- lookup cache id - empty for now

generate_expr (Arg _ index) = do
  emit_opcode Op_push_arg
  write (toInteger index)

generate_expr (Call callee (Loc _ args)) = do
  mapM_ generate_expr (reverse args)
  generate_expr callee
  emit_opcode Op_call
  write (toInteger $ length args)

generate_expr (List items) = do
  emit_opcode Op_alloc_list
  write (toInteger ((length items) + 1))
  mapM_ generate_expr items
    where generate_item item = do { generate_expr item
                                  ; emit_opcode Op_obj_store_at
                                  ; write 1
                                  }

generate_expr (BinaryOp (TcId op _) lhs rhs) = do
  generate_expr lhs
  generate_expr rhs

  emit_opcode Op_lookup
  unique_string op
  write 0 -- lookup cache disabled for now

  emit_opcode Op_call
  write 2 -- always 2 arguments

generate_expr expr = error ("Unhandled expr: " ++ (show expr))

generate_block :: Block TcId -> BytecodeState
generate_block (Block exprs) =
  mapM_ generate_expr exprs

generate_literal :: Literal -> BytecodeState
generate_literal (Number a) = do
  emit_opcode Op_push
  (case a of
     Left a -> write (toInteger a)
     Right a -> write (decode_double a))

generate_literal (String str) = do
  emit_opcode Op_load_string
  unique_string str

generate_function :: Function TcId -> BytecodeState
generate_function fn@Function { fn_name=(Loc _ (TcId name _)), params=params, body=body } = do
  bc <- get
  emit_opcode Op_create_closure
  write (toInteger . length $ functions bc)
  write 0 -- capturesScope
  (case name of
     "_" -> return ()
     _   -> emit_opcode Op_bind >> unique_string name)
  generate_function_source name params body

generate_function_source :: String -> [FunctionParameter TcId] -> Block TcId -> BytecodeState
generate_function_source name params body = do
  bc <- get
  put initialState { strings = strings bc }
  unique_string name
  write (toInteger $ length params)
  mapM_ Generator.param_name params
  generate_block body
  emit_opcode Op_ret
  bc2 <- get
  put $ bc {
    strings = strings bc2,
    functions = (functions bc) ++ (functions bc2) ++ [text bc2]
           }

param_name :: FunctionParameter TcId -> BytecodeState
param_name FunctionParameter { AST.param_name=(Loc _ (TcId name _)) } =
  unique_string name