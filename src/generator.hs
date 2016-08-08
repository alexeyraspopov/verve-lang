module Generator where

import AST
import Opcode

import Data.Bits (shiftL, (.|.))

data Bytecode = Bytecode {
  text :: [Integer],
  strings :: [String],
  functions :: [AST]
} deriving (Show)

generate :: AST -> Bytecode
generate program = generate_node (Bytecode [] [] []) program

emit_opcode :: Opcode -> Bytecode -> Bytecode
emit_opcode op bytecode =
  Bytecode ((text bytecode) ++ [toInteger $ fromEnum op]) (strings bytecode) (functions bytecode)

write :: Integer -> Bytecode -> Bytecode
write value bytecode =
  Bytecode ((text bytecode) ++ [value]) (strings bytecode) (functions bytecode)

unique_string :: String -> Bytecode -> (Bytecode, Integer)
unique_string str bytecode =
  (bytecode, toInteger 0)

decode_double :: Double -> Integer
decode_double double =
  let (significand, exponent) = decodeFloat double
   in (shiftL (toInteger exponent) 53) .|. significand

generate_node :: Bytecode -> AST -> Bytecode

generate_node bytecode (Program imports body) =
  let bc = foldl (\bytecode -> \node -> generate_node bytecode node) bytecode imports
   in foldl generate_node bc body

generate_node bytecode (Import pattern path alias) =
  bytecode

generate_node bytecode (Block nodes) =
  foldl generate_node bytecode nodes

generate_node bytecode (Number a) =
  let bc = emit_opcode Op_push bytecode
   in (case a of
         Left a -> write (toInteger a) bc
         Right a -> write (decode_double a) bc)

generate_node bytecode (String str) =
  let bc = emit_opcode Op_load_string bytecode
   in let (bc1, string_id) = unique_string str bc
       in write string_id bc1

generate_node bytecode (Identifier name) =
  let bc = emit_opcode Op_lookup bytecode
   in let (bc1, string_id) = unique_string name bc
       in write string_id bc1

generate_node bytecode (List items) =
  let bc = emit_opcode Op_alloc_list bytecode
   in let bc1 = write (toInteger ((length items) + 1)) bc
       in foldl generate_item bc1 items
      where generate_item bytecode item = let bc = generate_node bytecode item
                                           in let bc1 = emit_opcode Op_obj_store_at bc
                                               in write 1 bc1
