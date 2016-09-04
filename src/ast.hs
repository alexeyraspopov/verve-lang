module AST where

data AST = Program [AST] [AST]
         | Import (Maybe [String]) String (Maybe String)
         | Block [AST]
         | Number (Either Integer Double)
         | String String
         | Identifier String
         | List [AST]
         | UnaryOp String AST
         | BinaryOp String AST AST
         | If { condition :: AST, consequent :: AST , alternate :: Maybe AST }
         | Function { name :: String, generics :: Maybe [String], params :: [AST], ret_type :: Maybe AST, body :: AST }
         | Call AST [AST]
         | Interface String String [AST]
         | Implementation String AST [AST]
         | EnumType String (Maybe [String]) [AST]
         | TypeContructor String [AST]
         | FunctionType (Maybe [String]) [AST] AST
         | DataType String [AST]
         | BasicType String
         | Prototype String AST
         | Let [AST] AST
         | Assignment AST AST
         | FunctionParameter String Int (Maybe AST)
         | Match { value :: AST, cases :: [AST] }
         | Case { pattern :: AST, block :: AST }
         | Pattern { ctor :: String, bindings :: [String] }
         | Extern AST
         | Virtual AST
         deriving (Show, Eq)
