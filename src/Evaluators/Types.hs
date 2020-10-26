module Evaluators.Types (evalClass, evalType, evalInstanceOf) where

import Data.List
import Data.Maybe
import qualified Data.HashMap.Strict as HM
import Lens.Micro.Platform

import ParserTypes
import RunnerTypes
import RunnerUtils

evalClass :: Id -> [Pos TypeCons] -> Scoper Value
evalClass className constructors = do
    addToTypeScope className (VClass consNames)
    unionTopScope $ convert <$> getPosValue <$> constructors
    pure voidValue
  where
    convert :: TypeCons -> (Id, Value)
    convert (TypeCons name args) = (name, VTypeCons className name args)

    consNames = getTypeConsName . getPosValue <$> constructors

evalType :: Id -> [Pos DefSignature] -> Scoper Value
evalType typeName headers = do
    addToTypeScope typeName typeDef
    unionTopScope $ defSigToKeyValue <$> getPosValue <$> headers
    pure voidValue
  where
    typeDef = VTypeDef typeName $ getPosValue <$> headers

    defSigToKeyValue :: DefSignature -> (Id, Value)
    defSigToKeyValue defSig =
      (getDefSigFunName defSig, VTypeFunction defSig HM.empty)

evalInstanceOf :: Id -> Id -> [RExpr] -> Scoper Value
evalInstanceOf className typeName implementations = do
    classDef <- findInTypeScope className
    typeDef  <- findInTypeScope typeName
    funcDefs <- functionDefs typeDef
    
    if className == "List" then
      addAllImplementations ["Nil", "Cons"] funcDefs
    else case classDef of
      Just (VClass consNames) -> addAllImplementations consNames funcDefs
      _ -> stackTrace $ "Attempted to use undefined class: " <> className
  where
    functionDefs :: Maybe Value -> Scoper [DefSignature]
    functionDefs (Just (VTypeDef _ sigs)) = pure sigs
    functionDefs _ = stackTrace $ "Type " <> typeName <> " not found"

    addAllImplementations :: [Id] -> [DefSignature] -> Scoper Value
    addAllImplementations consNames funcDefs = do
      sequence_ $ (addImplementation className consNames funcDefs)
        <$> implementations
      pure voidValue

addImplementation :: Id -> [Id] -> [DefSignature] -> RExpr -> Scoper ()
addImplementation cname classTypeCons available
                  (RExprAssignment _ (IdArg name) (RExprDef _ args body)) = do
  sigArgs  <- getSigArgs name available
  caseArgs <- markArgs cname classTypeCons args sigArgs 
  addBodyToScope cname name body caseArgs
addImplementation _ _ _ _ =
  stackTrace "Every root expr in an implementation must be a def"

getSigArgs :: Id -> [DefSignature] -> Scoper [Arg]
getSigArgs cname cavailable =
  case find ((cname ==) . getDefSigFunName) cavailable of
    Just sig -> pure $ getDefSigArgs sig
    Nothing  -> stackTrace $
      cname <> " is not part of type " <> (getDefSigTypeName $ head cavailable)

updateStub :: Id -> Value -> [Arg] -> [RExpr] -> Scoper Value
updateStub cname stub caseArgs body =
  addToStub cname (FunctionCase caseArgs $ body) stub

markArgs :: Id -> [Id] -> [Arg] -> [Arg] -> Scoper [Arg]
markArgs cname classes argsA dargs =
  sequence $ (uncurry (validateArgs cname classes)) <$> zip dargs argsA

validateArgs :: Id -> [Id] -> Arg -> Arg -> Scoper Arg
validateArgs cname _ SelfArg (IdArg argName) = pure $ TypedIdArg argName cname
validateArgs cname classes SelfArg (PatternArg pname _) | not $ elem pname classes =
  stackTrace $ "Type constructor " <> pname <> " is not an " <> cname
validateArgs _ _ _ arg = pure arg

addBodyToScope :: Id -> Id -> [RExpr] -> [Arg] -> Scoper ()
addBodyToScope cname name body caseArgs = do
  maybeStub <- findInScope name
  case maybeStub of
    Just val -> (replaceInScope name =<< updateStub cname val caseArgs body)
    _        -> stackTrace $ name <> " is not in scope"
