module Parser.Semantic (ParseErr(..), ParseExcept, semantic) where

import Data.Maybe
import Data.Void
import Debug.Trace
import System.Exit
import Text.Megaparsec hiding (Pos)
import Control.Monad.Except
import Lens.Micro.Platform

import ParserTypes hiding (RExpr)
import RunnerUtils
import CallableUtils
import MorphUtils

import Evaluators.All

data ParseErr
  = ErrPos SourcePos String
  | ErrString String
  | ErrParse (ParseErrorBundle String Void)

instance Show ParseErr where
  show (ErrParse bundle) = errorBundlePretty bundle
  show (ErrPos p message) = message <> " at " <> show p
  show (ErrString message) = message

type ParseExcept = Except ParseErr

infixPrecedence :: [InfixOp]
infixPrecedence = [
    InfixMappend,
    InfixAdd,
    InfixSub,
    InfixMul,
    InfixDiv,
    InfixMod,
    InfixNe,
    InfixEq,
    InfixEq,
    InfixLe,
    InfixGe,
    InfixGt,
    InfixLt,
    InfixLogicAnd,
    InfixLogicOr
  ]

-- What a mess
groupByPrecedence :: [InfixOp] -> [(Maybe InfixOp, ET)] -> ET
groupByPrecedence [] [] = trace "How did I get here?" undefined
groupByPrecedence [] [(_, x)] = x
groupByPrecedence [] ((Just op, x):xs) =
  ET $ RInfix (getPos x) x op $ groupByPrecedence [] xs
groupByPrecedence (o:os) xs = joinHeadOp subCases
  where
    subCases :: [ET]
    subCases = groupByPrecedence os <$>
      (multiSpan ((== (Just o)) . (view _1)) xs)

    joinHeadOp :: [ET] -> ET
    joinHeadOp [y] = y
    joinHeadOp (y:ys) = foldl folderHeadOp y ys

    folderHeadOp :: ET -> ET -> ET
    folderHeadOp acc it = ET $ RInfix (getPos it) acc o it

semanticInfixChain :: ET -> [(InfixOp, ET)] -> ET
semanticInfixChain first rest =
    groupByPrecedence infixPrecedence ((Nothing, first):maybeRest)
  where
    maybeTup :: (InfixOp, ET) -> (Maybe InfixOp, ET)
    maybeTup (op, expr) = (Just op, expr) 

    maybeRest :: [(Maybe InfixOp, ET)]
    maybeRest = maybeTup <$> rest

semanticInfix :: PExpr -> InfixOp -> PExpr -> ParseExcept ET
semanticInfix lhs op rhs = do
  semanticLhs <- semantic lhs
  semanticRhs <- infixFlatten op rhs
  pure $ semanticInfixChain semanticLhs semanticRhs

infixFlatten :: InfixOp -> PExpr -> ParseExcept [(InfixOp, ET)]
infixFlatten op (Pos p (ExprInfix lhs nextOp rhs)) = do
  semanticLhs  <- semantic lhs
  semanticRest <- infixFlatten nextOp rhs
  pure $ (op, semanticLhs):semanticRest
infixFlatten op rhs = do
  semanticRhs  <- semantic rhs
  pure [(op, semanticRhs)]

semanticUnwrap :: [PExpr] -> ParseExcept ET
semanticUnwrap [] = throwError $ ErrString "Empty unwrap body"
semanticUnwrap [(Pos p (ExprBind _ _))] =
  throwError $ ErrPos p "Cannot have bind on last line of unwrap"
semanticUnwrap [last] = semantic last
semanticUnwrap ((Pos p (ExprBind arg expr)):xs) = do
  recursive    <- semanticUnwrap xs
  semanticExpr <- semantic expr

  pure $ ET $ RCall p
    (ET $ RId p "bind")
    [ET semanticExpr, ET $ RDef p [arg] [recursive]]
semanticUnwrap ((Pos p _):_) =
  throwError $ ErrPos p "All non-tails in unwrap must be binds"

semanticCondBlock :: CondBlock PExpr -> ParseExcept (CondBlock ET)
semanticCondBlock (CondBlock cond body) = do
  newCond <- semantic cond
  newBody <- sequence $ semantic <$> body
  pure $ CondBlock newCond newBody

semanticCaseBlock :: CaseBlock PExpr -> ParseExcept (CaseBlock ET)
semanticCaseBlock (CaseBlock p arg body) = do
  newBody <- sequence $ semantic <$> body
  pure $ CaseBlock p arg newBody

semanticInstanceDef :: PExpr -> ParseExcept (RAssignment RDef)
semanticInstanceDef = semanticAss semanticDef

semanticAss :: Evaluatable a
  => (PExpr -> ParseExcept a)
  -> PExpr
  -> ParseExcept (RAssignment a)
semanticAss rhsSemantic (Pos p (ExprAssignment arg value)) = do
  rhs <- rhsSemantic value
  pure $ RAssignment p arg rhs
semanticAss _ (Pos p _) = throwError $ ErrPos p $ "Not an assignment"

semanticDef :: PExpr -> ParseExcept RDef
semanticDef (Pos p (ExprDef args body)) = do
  newBody <- sequence $ semantic <$> body
  pure $ RDef p args newBody
semanticDef (Pos p _) = throwError $ ErrPos p $ "Not a def"

semantic :: PExpr -> ParseExcept ET
-- Actual semantic alterations
semantic (Pos p (ExprUnwrap body)) = do
  --semanticBodies <- sequence $ semantic <$> body
  semanticUnwrap body

semantic (Pos p (ExprInfix lhs op rhs)) =
  semanticInfix lhs op rhs

-- Traversals
semantic (Pos p (ExprPrefixOp op ex)) = do
  semanticEx <- semantic ex
  pure $ ET $ RPrefix p op semanticEx
semantic (Pos _ (ExprPrecedence inner)) =
  semantic inner
semantic (Pos p (ExprIfElse ifCond elifConds elseBody)) = do
  newIfCond    <- semanticCondBlock ifCond 
  newElifConds <- sequence $ semanticCondBlock <$> elifConds 
  newElseBody  <- sequence $ semantic          <$> elseBody
  pure $ ET $ RCondition p newIfCond newElifConds newElseBody
semantic ass@(Pos _ (ExprAssignment _ _)) = do
  ET <$> semanticAss semantic ass
semantic def@(Pos _ (ExprDef {})) = do
  ET <$> semanticDef def
semantic (Pos p (ExprCall func params)) = do
  newFunc <- semantic func 
  newParams <- sequence $ semantic <$> params 
  pure $ ET $ RCall p newFunc newParams
semantic (Pos p (ExprReturn retVal)) = do
  semantic retVal 
semantic (Pos p (ExprList elements)) = do
  newElements <- sequence $ semantic <$> elements 
  pure $ ET $ RList p newElements
semantic (Pos p (ExprTuple elements)) = do
  newElements <- sequence $ semantic <$> elements 
  pure $ ET $ RTuple p newElements
semantic (Pos p (ExprInstanceOf tname cname elements)) = do
  newElements <- sequence $ semanticInstanceDef <$> elements
  pure $ ET $ RInstanceOf p tname cname newElements
semantic (Pos p (ExprCase input blocks)) = do
  newInput <- semantic input
  newBlocks <- sequence $ semanticCaseBlock <$> blocks
  pure $ ET $ RCase p newInput newBlocks
-- One to one maps
semantic (Pos p (ExprClass cname typeCons)) = do
  pure $ ET $ RClass p cname typeCons
semantic (Pos p (ExprType tname defSigs)) = do
  pure $ ET $ RType p tname defSigs
semantic (Pos p (ExprId name)) = do
  pure $ ET $ RId p name
semantic (Pos p (ExprChar value)) = do
  pure $ ET $ RChar p value
semantic (Pos p (ExprInt value)) = do
  pure $ ET $ RInt p value
semantic (Pos p (ExprDouble value)) = do
  pure $ ET $ RDouble p value

semantic (Pos p other) = throwError $ ErrPos p $
  "Unexpected expr in semnatic: " <> show other