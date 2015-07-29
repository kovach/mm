{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Converts the parser's AST into the core AST.
module Language.Plover.Convert where

import Language.Plover.ParserTypes
import Language.Plover.ErrorUtil
import Data.Tag
import Text.ParserCombinators.Parsec.Pos
import Control.Monad
import Control.Applicative ((<$>), (<*>))
import qualified Language.Plover.Types as T

data ConvertError = ConvertError !SourcePos [String]
                  deriving (Show)

makePos :: Expr -> SourcePos
makePos (PExpr tag _) = makePos' tag
  where makePos' NoTag = newPos "<unknown>" (-1) (-1)
        makePos' (Tag a _) = a
        makePos' (ProvTag _ mt) = makePos' mt
        makePos' (MergeTags {}) = error "Unexpected MergeTags in makePos (parser doesn't generate these)"

makeExpr :: Expr -> Either ConvertError T.CExpr
makeExpr exp@(PExpr pos e') = case e' of
  Vec [] e -> makeExpr e
  Vec ((v,r):bs) e -> T.Vec pos v <$> makeRange r <*> makeExpr (PExpr pos (Vec bs e))
  For [] e -> makeExpr e
  For ((v,r):bs) e -> T.For pos v <$> makeRange r <*> makeExpr (PExpr pos (For bs e))
  Sum [] e -> makeExpr e
  Sum ((v,r):bs) e -> (T.Unary pos T.Sum .) . T.Vec pos v <$> makeRange r <*> makeExpr (PExpr pos (Sum bs e))
  Ref v -> return $ T.Get pos $ T.Ref (T.TypeHole Nothing) v
  T -> Left $ ConvertError (makePos exp) ["Unexpected transpose operator in non-exponent position"]
  Hole -> return $ T.Hole pos Nothing
  IntLit t i -> return $ T.IntLit pos t i
  FloatLit t x -> return $ T.FloatLit pos t x
  BoolLit b -> return $ T.BoolLit pos b
  StrLit s -> return $ T.StrLit pos s
  VecLit es -> T.VecLit pos (T.TypeHole Nothing) <$> mapM makeExpr es
  If a b c -> T.If pos <$> makeExpr a <*> makeExpr b <*> makeExpr c
  Return e -> T.Return pos (T.TypeHole Nothing) <$> makeExpr e
  Assert e -> T.Assert pos <$> makeExpr e
  UnExpr Deref a -> T.Get pos . T.Deref <$> makeExpr a
  UnExpr Addr a -> T.Addr pos <$> makeLocation a
  UnExpr op a -> T.Unary pos (tr op) <$> makeExpr a
    where tr Pos = T.Pos
          tr Neg = T.Neg
          tr Deref = error "Not translatable here"
          tr Transpose = T.Transpose
          tr Inverse = T.Inverse
          tr Not = T.Not
  BinExpr Pow a (PExpr _ T) -> -- A^T is transpose of A
    T.Unary pos T.Transpose <$> makeExpr a
  BinExpr Pow a (PExpr _ (UnExpr Neg (PExpr _ (IntLit _ 1)))) -> -- A^(-1) is A inverse
    T.Unary pos T.Inverse <$> makeExpr a
  BinExpr Pow a (PExpr _ (UnExpr Neg (PExpr _ T))) -> -- A^(-T) is transpose of A inverse
    T.Unary pos T.Transpose . T.Unary pos T.Inverse <$> makeExpr a
  BinExpr Type a b -> T.AssertType pos <$> makeExpr a <*> makeType b
  BinExpr op a b -> T.Binary pos (tr op) <$> makeExpr a <*> makeExpr b
    where tr Add = T.Add
          tr Sub = T.Sub
          tr Mul = T.Mul
          tr Hadamard = T.Hadamard
          tr Div = T.Div
          tr Pow = T.Pow
          tr Concat = T.Concat
          tr Type = error "Not translatable here"
          tr And = T.And
          tr Or = T.Or
          tr EqualOp = T.EqOp
          tr LTOp = T.LTOp
          tr LTEOp = T.LTEOp

  Field {} -> T.Get pos <$> makeLocation exp
  Index {} -> T.Get pos <$> makeLocation exp

  Tuple xs -> T.TupleLit pos <$> mapM makeExpr xs
  Range {} -> T.RangeVal pos <$> makeRange exp

  App f args -> T.App pos <$> makeExpr f <*> (forM args' $ \arg -> case arg of
                                                Arg a -> T.Arg <$> makeExpr a
                                                ImpArg a -> T.ImpArg <$> makeExpr a)
    where args' = filter novoid args
          novoid (Arg (PExpr _ VoidExpr)) = False
          novoid _ = True
  SeqExpr xs -> makeSequence pos xs
  DefExpr _ _ -> Left $ ConvertError (makePos exp) ["Unexpected definition outside sequence."]
  StoreExpr loc a -> T.Set pos <$> makeLocation loc <*> makeExpr a

  Extern _ -> Left $ ConvertError (makePos exp) ["Non-toplevel extern."]
  Static _ -> Left $ ConvertError (makePos exp) ["Non-toplevel static."]
  _ -> Left $ ConvertError (makePos exp) ["Unexpected or unimplemented expression."]

makeLocation :: Expr -> Either ConvertError (T.Location T.CExpr)
makeLocation exp@(PExpr pos e') = case e' of
  Field a n -> T.Field <$> makeExpr a <*> pure n
  Index a (PExpr _ (Tuple idxs)) -> T.Index <$> makeExpr a <*> mapM makeExpr idxs
  Index a b -> T.Index <$> makeExpr a <*> (return <$> makeExpr b)
  UnExpr Deref a -> T.Deref <$> makeExpr a
  Ref v -> return $ T.Ref (T.TypeHole Nothing) v
  _ -> Left $ ConvertError (makePos exp) ["Expecting location."]

makeRange :: Expr -> Either ConvertError (T.Range T.CExpr)
makeRange exp@(PExpr pos e') = case e' of
  Range start stop step -> do start' <- maybe (return $ T.IntLit pos T.defaultIntType 0) makeExpr start
                              stop' <- maybe (return $ T.Hole pos Nothing) makeExpr stop
                              step' <- maybe (return $ T.IntLit pos T.defaultIntType 1) makeExpr step
                              return $ T.Range start' stop' step'
  _ -> do ee <- makeExpr exp
          return $ T.Range (T.IntLit pos T.defaultIntType 0) ee (T.IntLit pos T.defaultIntType 1)

makeSequence :: Tag SourcePos -> [Expr] -> Either ConvertError T.CExpr
makeSequence pos [] = return $ T.VoidExpr pos
makeSequence pos (x@(PExpr pos' x') : xs) = case x' of
  DefExpr (PExpr pos2 a) b
    | null xs -> Left $ ConvertError (makePos x) ["Definition cannot be last thing in sequence."]
    | otherwise -> case a of
      BinExpr Type av at -> -- ((av :: at) := b; ...) => (av := (b :: at); ...)
        makeSequence pos $ (wrapTag pos' $ DefExpr av $ wrapTag pos2 $ BinExpr Type b at) : xs
      Ref v -> T.Let pos' v <$> makeExpr b <*> makeSequence pos xs
      _ -> Left $ ConvertError (makePos x) ["Expecting symbol for definition."]
  BinExpr Type (PExpr pos'' (Ref v)) vt
    | null xs -> Left $ ConvertError (makePos x) ["Definition cannot be last thing in sequence."]
    | otherwise -> T.Let pos' v . T.Uninitialized pos'' <$> makeType vt <*> makeSequence pos xs
  _ | null xs -> makeExpr x
    | otherwise -> T.Seq pos <$> makeExpr x <*> makeSequence pos xs


makeType :: Expr -> Either ConvertError T.Type
makeType exp@(PExpr _ e') = case e' of
  Index a (PExpr _ (Tuple idxs)) -> T.VecType T.DenseMatrix <$> mapM makeExpr idxs <*> makeType a
  Index a b -> T.VecType T.DenseMatrix <$> (return <$> makeExpr b) <*> makeType a
  App (PExpr _ (Ref v)) args -> makeTypeFunc (makePos exp) v args
  -- (no way to write the type of a function.)
  Ref v -> case v of
    "u8" -> return $ T.IntType T.U8
    "s8" -> return $ T.IntType T.S8
    "u16" -> return $ T.IntType T.U16
    "s16" -> return $ T.IntType T.S16
    "u32" -> return $ T.IntType T.U32
    "s32" -> return $ T.IntType T.S32
    "u64" -> return $ T.IntType T.U64
    "s64" -> return $ T.IntType T.S64
    "int" -> return $ T.IntType T.defaultIntType
    "float" -> return $ T.FloatType T.Float
    "double" -> return $ T.FloatType T.Double
    "string" -> return $ T.StringType
    "bool" -> return $ T.BoolType
    _ -> return $ T.TypedefType v
  UnExpr Deref a -> T.PtrType <$> makeType a
  Tuple xs -> T.TupleType <$> mapM makeType xs
  Hole -> return $ T.TypeHole Nothing
  _ -> Left $ ConvertError (makePos exp) ["Expecting type"]

makeTypeFunc :: SourcePos -> String -> [Arg Expr] -> Either ConvertError T.Type
makeTypeFunc pos v args = case v of
  "Dense" -> vecStoreType T.DenseMatrix
  "Diagonal" -> vecStoreType T.DiagonalMatrix
  "UpperTriangular" -> vecStoreType T.UpperTriangular
  "UpperUnitTriangular" -> vecStoreType T.UpperUnitTriangular
  "LowerTriangular" -> vecStoreType T.LowerTriangular
  "LowerUnitTriangular" -> vecStoreType T.LowerUnitTriangular
  "Symmetric" -> vecStoreType T.SymmetricMatrix
  _ -> Left $ ConvertError pos ["Unknown type-level function."]

  where vecStoreType st = case args of
          [Arg a] -> do aty <- makeType a
                        case aty of
                          T.VecType _ bnds bty -> return $ T.VecType st bnds bty
                          _ -> Left $ ConvertError (makePos a) ["Expecting matrix type."]
          _ -> Left $ ConvertError pos ["Expecting exactly one type argument to type-level function."]

makeDefs :: Expr -> Either ConvertError [T.DefBinding]
makeDefs exp@(PExpr pos pe) = case pe of
  SeqExpr xs -> fmap join $ mapM makeDefs xs
  Extern a -> fmap (map (\z -> z { T.extern = True })) $ makeDefs a
  Static a -> fmap (map (\z -> z { T.static = True })) $ makeDefs a
  BinExpr Type a b -> return <$> makeTopType exp Nothing
  DefExpr a b -> return <$> (makeTopType a . Just =<< makeExpr b)
  Struct v members -> return <$> makeStructDecl pos v members
  _ -> Left $ ConvertError (makePos exp) ["Unexpected top-level form."]

makeStructDecl :: Tag SourcePos -> Variable -> [Expr] -> Either ConvertError T.DefBinding
makeStructDecl pos v members = T.mkBinding pos v . T.StructDef <$> mapM makeStructMember members
  where makeStructMember (PExpr _ (BinExpr Type (PExpr pos (Ref v)) b)) = do t <- makeType b
                                                                             return (v, (pos, t))
        -- TODO parse asserts inside struct
        makeStructMember exp = Left $ ConvertError (makePos exp) ["Expecting member in struct."]

makeTopType :: Expr -> Maybe T.CExpr -> Either ConvertError T.DefBinding
makeTopType exp@(PExpr _ pe) val = case pe of
  BinExpr Type (PExpr pos (Ref v)) b -> T.mkBinding pos v . T.ValueDef val <$> makeType b
  BinExpr Type (PExpr pos (App (PExpr pos' (Ref v)) args)) b ->
    do t <- makeType b
       at <- funArgs args
       return $ T.mkBinding pos' v $ T.FunctionDef val $ T.FnT at t
  _ -> Left $ ConvertError (makePos exp) ["Expecting variable or function type definition (possibly missing return type)."]


funArgs :: [Arg Expr] -> Either ConvertError [(Tag SourcePos, Variable, Bool, T.ArgDir, T.Type)]
funArgs [] = return []
funArgs ((Arg e@(PExpr _ pe)):args) = case pe of
  BinExpr Type (PExpr pos (Ref v)) b  -> do t <- makeType b
                                            ([(pos, v, True, T.ArgIn, t)] ++) <$> funArgs args
  BinExpr Type (PExpr _ (App (PExpr _ (Ref dir)) [Arg (PExpr pos (Ref v))])) b -> do
    dir <- decodeDir dir
    t <- makeType b
    ([(pos, v, True, dir, t)] ++) <$> funArgs args

    where decodeDir dir = case dir of
            "in" -> Right T.ArgIn
            "out" -> Right T.ArgOut
            "inout" -> Right T.ArgInOut
            _ -> Left $ ConvertError (makePos e) ["Invalid argument direction specifier " ++ show dir]
  VoidExpr -> funArgs args
  _ -> Left $ ConvertError (makePos e) ["Bad argument definition."]
funArgs ((ImpArg e@(PExpr pos pe)):args) = case pe of
  Tuple idxs -> funArgs ((map ImpArg idxs) ++ args) -- shorthand: f {n,m}
  Ref v -> ([(pos, v, False, T.ArgIn, T.IntType T.IDefault)] ++) <$> funArgs args
  BinExpr Type (PExpr pos' (Ref v)) b  -> do t <- makeType b
                                             ([(pos', v, False, T.ArgIn, t)] ++) <$> funArgs args
  _ -> Left $ ConvertError (makePos e) ["Bad implicit argument definition."]

reportConvertErr :: ConvertError
                 -> IO String
reportConvertErr (ConvertError pos messages)
  = do sl <- showLineFromFile pos
       return $ "Error at " ++ sl
         ++ "\n" ++ (unlines messages)