{-# LANGUAGE PatternSynonyms #-}
module Language.Plover.SemCheck where

import Debug.Trace
import Language.Plover.ErrorUtil
import Language.Plover.Types
import Language.Plover.UsedNames
import Language.Plover.Unify hiding (gensym)
import qualified Data.Map as M
import Data.Map (Map)
import Data.Tag
import Data.Function
import Data.Maybe
import Data.List
import qualified Text.PrettyPrint as PP
import Control.Monad
import Control.Monad.State
import Control.Applicative ((<$>), (<*>), (<*), pure)
import Text.ParserCombinators.Parsec (SourcePos)

data SemError = SemError (Tag SourcePos) String
              | SemRebound (Tag SourcePos) Variable
              | SemUnbound (Tag SourcePos) Variable
              | SemUnboundType (Tag SourcePos) Variable
              | SemStorageError (Tag SourcePos) Type Type
              | SemUniError UnificationError
              | SemNoisyHole (Tag SourcePos) (Maybe Type) (Maybe CExpr)
              deriving (Show, Eq, Ord)

reportSemErr :: SemError
             -> IO String
reportSemErr err
  = case err of
     SemError tag msg -> posStuff tag $ msg ++ "\n"
     SemRebound tag v -> posStuff tag $ "Cannot redefine identifier " ++ show v ++ ".\n"
     SemUnbound tag v -> posStuff tag $ "Unbound identifier " ++ show v ++ ".\n"
     SemUnboundType tag v -> posStuff tag $ "Unbound type " ++ show v ++ ".\n"
     SemStorageError tag ty1 ty2 -> posStuff tag $ "Expecting\n"
                                    ++ nice ty1 ++ "\nbut given\n" ++ nice ty2 ++ "\n"
     SemUniError err -> case err of
       UError tag msg -> posStuff tag $ msg ++ "\n"
       UTyFailure tag t1 t2 -> posStuff tag $ "Could not unify type\n"
                               ++ nice t1 ++ "\nwith type\n" ++ nice t2 ++ "\n"
       UTyAssertFailure tag sty dty -> posStuff tag $ "The type\n" ++ nice sty
                                       ++ "\nis not a subtype of\n" ++ nice dty ++ "\n"
       UExFailure tag e1 e2 -> posStuff tag $ "Could not unify expression\n"
                               ++ nice e1 ++ "\nwith expression\n" ++ nice e2 ++ "\n"
       ULocFailure tag l1 l2 -> posStuff tag $ "Could not unify location\n"
                                ++ nice l1 ++ "\nwith location\n" ++ nice l2 ++ "\n"
       UTyOccurs tag v ty -> posStuff tag $ "Occurs check error for " ++ show v
                             ++ " in type\n" ++ nice ty ++ "\n"
       UExOccurs tag v ex -> posStuff tag $ "Occurs check error for " ++ show v
                             ++ " in expression\n" ++ nice ex ++ "\n"
       URefOccurs tag v ty -> posStuff tag $ "Variable " ++ show v
                              ++ " occurs in type\n" ++ nice ty ++ "\n"
       UNoField tag v -> posStuff tag $ "No such field " ++ show v ++ "\n"
       UGenTyError tag ty msg -> posStuff tag $ msg ++ "\n" ++ nice ty ++ "\n"
     SemNoisyHole tag Nothing Nothing -> posStuff tag $ "Noisy hole with unknown type or value.\n"
     SemNoisyHole tag (Just ty) Nothing -> posStuff tag $ "Noisy hole of type\n" ++ nice ty ++ "\n"
     SemNoisyHole tag Nothing (Just ex) -> posStuff tag $ "Noisy hole with value\n" ++ nice ex ++ "\n"
     SemNoisyHole tag (Just ty) (Just ex) -> posStuff tag $ "Noisy hole of type\n" ++ nice ty ++ "\nand value\n" ++ nice ex ++ "\n"
  where posStuff tag s = do sls <- mapM showLineFromFile (sort $ nub $ getTags tag)
                            return $ "Error " ++ unlines (("at " ++) <$> sls) ++ s
        nice :: (Show a, PP a) => a -> String
        nice t = show $ PP.nest 3 $ if True then pretty t else PP.text $ show t


data SemCheckData = SemCheckData
                    { semErrors :: [SemError]
                    , gensymState :: [String] -- ^ already-used variables
                    , globalBindings :: Map Variable DefBinding
                    , localBindings :: Map Variable (Tag SourcePos, Variable) -- ^ for α-renaming
                    , semRetType :: Type -- the current function's return type
                    , semNoisyHoles :: Map Variable (Tag SourcePos)
                    }
                  deriving Show

newSemCheckData :: [UVar] -> SemCheckData
newSemCheckData vs = SemCheckData
                     { semErrors = []
                     , gensymState = vs
                     , globalBindings = M.empty
                     , localBindings = M.empty
                     , semRetType = error "semRetType not defined"
                     , semNoisyHoles = M.empty
                     }

type SemChecker = State SemCheckData

runSemChecker :: SemChecker v -> Either [SemError] v
runSemChecker m = let (v, s) = runState m (newSemCheckData [])
                  in case semErrors s of
                      [] -> Right v
                      errs -> Left errs

isOkIdentifier :: String -> Bool
isOkIdentifier (x:xs) = x `elem` okStart && all (`elem` okRest) xs
  where okStart = ['A'..'Z'] ++ ['a'..'z'] ++ "_"
        okRest = okStart ++ ['0'..'9']

recordNoisyHole :: Variable -> Tag SourcePos -> SemChecker ()
recordNoisyHole v tag = modify $ \state ->
  state { semNoisyHoles = M.insert v tag $ semNoisyHoles state }
noisyHoleNames :: SemChecker [Variable]
noisyHoleNames = M.keys <$> semNoisyHoles <$> get

-- | Phases:
-- 1. merge top level bindings
-- 2. alpha rename
-- 3. concretize applications
-- 4. fill holes
-- 5. expand typedefs
-- 6. unify
-- 7. verify storage types in assignments, arguments, and returns
doSemCheck :: [DefBinding] -> Either [SemError] [DefBinding]
doSemCheck defs = runSemChecker dochecks
  where dochecks = do modify $ \state -> state { gensymState = allToplevelNames defs }
                      condenseBindings defs -- introduces global bindings
                      checkFuncBodies
                      globalCheckTypedefs
                      globalAlphaRename
                      globalConcretizeApps
                      globalFillHoles

                      defsMap' <- globalBindings <$> get
                      let defs' = map (defsMap' M.!) names

                      he <- hasErrors
                      nhnames <- noisyHoleNames
                      if not he
                        then case runUM defs' nhnames (typeCheckToplevel defs') of
                          Right (nhdata, defs'') -> do noisyHolesAreErrors nhnames nhdata
                                                       topVerifyStorage defs''
                                                       return defs''
                          Left errs -> do mapM_ (addError . SemUniError) errs
                                          return []
                        else return []
        names = nub $ map binding defs

noisyHolesAreErrors :: [Variable] -> HoleData -> SemChecker ()
noisyHolesAreErrors holes (htys, hexs) = do
  hmap <- semNoisyHoles <$> get
  forM_ holes $ \hole -> do
    addError $ SemNoisyHole (hmap M.! hole) (M.lookup hole htys) (M.lookup hole hexs)

gensym :: String -> SemChecker String
gensym prefix = do names <- gensymState <$> get
                   gensym' (length names) names
  where gensym' :: Int -> [String] -> SemChecker String
        gensym' i names = if newName `elem` names
                          then gensym' (1 + i) names
                          else do modify $ \state -> state { gensymState = newName : gensymState state }
                                  return newName
          where newName = prefix ++ "$" ++ show i

-- | Generates a fresh variable name.
genVar :: SemChecker Variable
genVar = gensym ""

-- | Generates a fresh unification variable with a given prefix
genUVarP :: String -> SemChecker UVar
genUVarP = gensym

-- | Generates a fresh unification variable
genUVar :: SemChecker UVar
genUVar = genUVarP ""

addError :: SemError -> SemChecker ()
addError e = do sd <- get
                put $ sd { semErrors = semErrors sd ++ [e] }

hasErrors :: SemChecker Bool
hasErrors = not . null . semErrors <$> get

-- | Adds the error to the error list if the condition is false.
semAssert :: Bool -> SemError -> SemChecker ()
semAssert b e = if b then return () else addError e

lookupGlobalType :: Variable -> SemChecker (Maybe Type)
lookupGlobalType v = do bindings <- globalBindings <$> get
                        case M.lookup v bindings of
                         Just def -> return $ Just $ definitionType def
                         Nothing -> return Nothing

lookupSym :: Variable -> SemChecker (Maybe (Maybe Type, Variable))
lookupSym v = do bindings <- localBindings <$> get
                 case M.lookup v bindings of
                  Just (pos, v') -> return $ Just (Nothing, v')
                  Nothing -> do mt <- lookupGlobalType v
                                case mt of
                                 Just _ -> return $ Just (mt, v)
                                 Nothing -> return Nothing

resetLocalBindings :: SemChecker ()
resetLocalBindings = modify $ \state -> state { localBindings = M.empty }

withNewScope :: SemChecker v -> SemChecker v
withNewScope m = do bindings <- localBindings <$> get
                    v <- m
                    modify $ \state -> state { localBindings = bindings }
                    return v

-- | adds a new binding, and if one already exists, return the tag for
-- it.  The v' is for α-renaming, and it should come from gensym.
addNewLocalBinding :: Tag SourcePos -> Variable -> Variable -> SemChecker (Maybe (Tag SourcePos))
addNewLocalBinding pos v v' = do bindings <- localBindings <$> get
                                 modify $ \state -> state { localBindings = M.insert v (pos, v')
                                                                            bindings }
                                 case M.lookup v bindings of
                                  Just (pos, _) -> return $ Just pos
                                  Nothing -> return Nothing

-- | Take the list of bindings and convert them into a map of
-- filled-out bindings.  This is to support prototypes.
condenseBindings :: [DefBinding] -> SemChecker ()
condenseBindings defs = do mapM_ addGlobalBinding defs

lookupGlobalBinding :: Variable -> SemChecker (Maybe DefBinding)
lookupGlobalBinding v = M.lookup v . globalBindings <$> get

-- | Adds a global binding, though if one already exists with that
-- name, attempts to reconcile.
addGlobalBinding :: DefBinding -> SemChecker ()
addGlobalBinding def = do molddef <- lookupGlobalBinding (binding def)
                          case molddef of
                           Just olddef -> reconcileBindings olddef def
                           Nothing -> newBinding def

-- | Determines whether a definition has a value definition.  Struct
-- declarations don't count as having values.  This is for the purpose
-- of seeing whether extern declarations have an associated value.
defHasValue :: DefBinding -> Bool
defHasValue (DefBinding { definition = def }) = case def of
  FunctionDef me _ -> isJust me
  StructDef _ -> False
  ValueDef me _ -> isJust me
  TypeDef _ -> False
  InlineCDef {} -> False

-- | This is a new binding, not already in the SemChecker state.  Put
-- it there, and do some consistency checks.
newBinding :: DefBinding -> SemChecker ()
newBinding def = do
  modify $ \state -> state { globalBindings = M.insert (binding def) def (globalBindings state) }
  semAssert (not (extern def && defHasValue def)) $
    SemError (bindingPos def) "Extern definition cannot have value or function body."
  semAssert (not (extern def && static def)) $
    SemError (bindingPos def) "Cannot be both static and extern simultaneously."
  semAssert (not (is_inline def && extern def)) $
    SemError (bindingPos def) "Inline C may not be 'extern'."
  where is_inline defb = case definition defb of
          InlineCDef {} -> True
          _ -> False

-- | These two bindings are for the same variable.  Make sure they are
-- reconcilable, and bring them into a single binding (stored in the
-- SemChecker state)
reconcileBindings :: DefBinding -> DefBinding -> SemChecker ()
reconcileBindings oldDef newDef | isImported oldDef || isImported newDef = do
  semAssert (isImported oldDef && isImported newDef) $
    SemError rtag "Cannot redefine imported symbol."
  semAssert (imported oldDef == imported newDef) $
    SemError rtag "Different modules may not define the same symbol."
  let newDef' = oldDef { static = static oldDef && static newDef }
      v = binding newDef'
  modify $ \state -> state { globalBindings = M.insert v newDef' (globalBindings state) }
  where rtag = MergeTags [bindingPos oldDef, bindingPos newDef]
reconcileBindings oldDef newDef = do
  semAssert (extern oldDef || not (extern newDef)) $
    SemError rtag "Conflicting extern modifiers."
  semAssert (static oldDef || not (static newDef)) $
    SemError rtag "Conflicting static modifiers."
  semAssert (not (defHasValue oldDef)) $
    SemError rtag "Cannot redefine definition which already has a value or function body."
  semAssert (not (extern oldDef && defHasValue newDef)) $
    SemError rtag "Cannot give value to prototyped extern definition."
  definition' <- reconcileDefinitions rtag (definition oldDef) (definition newDef)
  let newDef' = oldDef { bindingPos = rtag
                       , definition = definition' }
      v = binding newDef'
  modify $ \state -> state { globalBindings = M.insert v newDef' (globalBindings state) }
  where rtag = MergeTags [bindingPos oldDef, bindingPos newDef]

reconcileDefinitions :: Tag SourcePos -> Definition -> Definition -> SemChecker Definition
reconcileDefinitions tag (FunctionDef oldMce oldFt) (FunctionDef newMce newFt) = do
  semAssert (oldFt == newFt) $ SemError tag "Inconsistent function types."
  return $ FunctionDef (oldMce `mplus` newMce) oldFt
reconcileDefinitions tag (ValueDef oldMce oldType) (ValueDef newMce newType) = do
  semAssert (oldType == newType) $ SemError tag "Inconsistent global variable types."
  return $ ValueDef (oldMce `mplus` newMce) oldType
reconcileDefinitions tag (StructDef oldMembers) (StructDef newMembers) = do
  semAssert (oldMembers == newMembers) $ SemError tag "Inconsistent structure definitions."
  return $ StructDef oldMembers
reconcileDefinitions tag (TypeDef oldTy) (TypeDef newTy) = do
  semAssert (oldTy == newTy) $ SemError tag "Inconsistent type definitions."
  return $ TypeDef oldTy
reconcileDefinitions tag oldDef newDef = do
  addError $ SemError tag "Redefinition of global variable with inconsistent types."
  return oldDef

checkFuncBodies :: SemChecker ()
checkFuncBodies = do defbs <- M.elems . globalBindings <$> get
                     forM_ defbs $ \defb -> case definition defb of
                       FunctionDef mexp ft -> do when (not (isImported defb) && not (extern defb) && isNothing mexp) $
                                                   addError $
                                                   SemError (bindingPos defb) "Function missing body."
                                                 let FnT args mva retty = ft
                                                 when (not (extern defb) && isJust mva) $
                                                   addError $
                                                   SemError (bindingPos defb) "Non-extern functions may not be declared with varargs."
                       _ -> return ()


-- | N.B. Resets local bindings between passes
globalAlphaRename :: SemChecker ()
globalAlphaRename = do defbs <- M.elems . globalBindings <$> get
                       defbs' <- mapM doAlphaRename defbs
                       modify $ \state -> state { globalBindings = M.fromList [(binding d, d) | d <- defbs'] }
  where doAlphaRename defb = do resetLocalBindings
                                let pos = bindingPos defb
                                def' <- case definition defb of
                                  FunctionDef mexp ft -> do idcheck pos defb
                                                            ft' <- alphaRenameFunType pos ft
                                                            mexp' <- mapM (alphaRenameTerms pos) mexp
                                                            return $ FunctionDef mexp' ft'
                                  ValueDef mexp ty -> do idcheck pos defb
                                                         ty' <- alphaRenameTerms pos ty
                                                         mexp' <- mapM (alphaRenameTerms pos) mexp
                                                         return $ ValueDef mexp' ty'
                                  StructDef members -> do idcheck pos defb
                                                          StructDef <$> alphaRenameStructMembers members
                                  TypeDef ty -> do idcheck pos defb
                                                   return $ TypeDef ty
                                  InlineCDef {} -> return $ definition defb
                                return $ defb { definition = def' }
        idcheck pos defb = semAssert (isOkIdentifier $ binding defb) $
                           SemError pos "Top-level identifiers must be valid as C identifiers."


-- | Check for undefined variables, and α-rename.
alphaRenameFunType :: Tag SourcePos -> FunctionType -> SemChecker FunctionType
alphaRenameFunType pos (FnT args mva rty) = do
  args' <- forM args $ \(vpos, v, req, dir, vty) -> do
    v' <- gensym v
    vty' <- alphaRenameTerms vpos vty
    mlastpos <- addNewLocalBinding vpos v v'
    case mlastpos of
      Just otag -> do
        addError $ SemError (MergeTags [otag, vpos]) $
          "Redefinition of parameter " ++ show v ++ " in function type."
      Nothing -> return ()
    return (vpos, v', req, dir, vty')
  rty' <- alphaRenameTerms pos rty
  return $ FnT args' mva rty'

-- | Alpha-renaming is a misnomer: we are merely checking that members
-- are defined at most once and are defined when used.
alphaRenameStructMembers :: [StructMember] -> SemChecker [StructMember]
alphaRenameStructMembers members = do
  forM_ members $ \(v, (pos, exty, inty)) -> do
    alphaRenameTerms pos exty -- check that external types do not refer to anything inside struct
  forM members $ \(v, (pos, exty, inty)) -> do
    exty' <- alphaRenameTerms pos exty
    inty' <- alphaRenameTerms pos inty
    mlastpos <- addNewLocalBinding pos v v -- Use same binding because we do not rename struct members
    case mlastpos of
      Just otag -> do
        addError $ SemError (MergeTags [otag, pos]) $
          "Redefinition of member " ++ show v ++ " in struct."
      Nothing -> return ()
    return (v, (pos, exty', inty'))

-- | Add implicit arguments to function applications.
globalConcretizeApps :: SemChecker ()
globalConcretizeApps = do defbs <- M.elems . globalBindings <$> get
                          defbs' <- mapM doConcretize defbs
                          modify $ \state -> state { globalBindings = M.fromList [(binding d, d) | d <- defbs'] }
  where doConcretize defb = do let pos = bindingPos defb
                               def' <- case definition defb of
                                 FunctionDef mexp ft -> do ft' <- concretizeFunType ft
                                                           mexp' <- mapM concretizeApps mexp
                                                           return $ FunctionDef mexp' ft'
                                 ValueDef mexp ty -> do ty' <- concretizeApps ty
                                                        mexp' <- mapM concretizeApps mexp
                                                        return $ ValueDef mexp' ty'
                                 StructDef members -> StructDef <$> concretizeStructMembers members
                                 TypeDef ty -> TypeDef <$> concretizeApps ty
                                 InlineCDef {} -> return $ definition defb
                               return $ defb { definition = def' }

concretizeFunType :: FunctionType -> SemChecker FunctionType
concretizeFunType (FnT args mva rty) = do
  args' <- forM args $ \(vpos, v, req, dir, vty) -> do
    vty' <- concretizeApps vty
    return (vpos, v, req, dir, vty')
  rty' <- concretizeApps rty
  return $ FnT args' mva rty'

concretizeStructMembers :: [StructMember] -> SemChecker [StructMember]
concretizeStructMembers members = forM members $ \(v, (pos, exty, inty)) -> do
  exty' <- concretizeApps exty
  inty' <- concretizeApps inty
  return (v, (pos, exty', inty'))

-- | This fills the holes in each top-level definition.
globalFillHoles :: SemChecker ()
globalFillHoles = do defbs <- M.elems . globalBindings <$> get
                     defbs' <- mapM doFill defbs
                     modify $ \state -> state { globalBindings = M.fromList [(binding d, d) | d <- defbs'] }
  where doFill defb = do let pos = bindingPos defb
                         def' <- case definition defb of
                           FunctionDef mexp ft -> do ft' <- fillFunType ft
                                                     mexp' <- mapM fillTermHoles mexp
                                                     return $ FunctionDef mexp' ft'
                           ValueDef mexp ty -> do ty' <- fillTermHoles ty
                                                  mexp' <- mapM fillTermHoles mexp
                                                  return $ ValueDef mexp' ty'
                           StructDef members -> StructDef <$> fillStructMembers members
                           TypeDef ty -> TypeDef <$> fillTermHoles ty
                           InlineCDef {} -> return $ definition defb
                         return $ defb { definition = def' }

fillFunType :: FunctionType -> SemChecker FunctionType
fillFunType (FnT args mva rty) = do
  args' <- forM args $ \(vpos, v, req, dir, vty) -> do
    vty' <- fillTermHoles vty
    return (vpos, v, req, dir, vty')
  rty' <- fillTermHoles rty
  return $ FnT args' mva rty'

fillStructMembers :: [StructMember] -> SemChecker [StructMember]
fillStructMembers members = forM members $ \(v, (pos, exty, inty)) -> do
  exty' <- fillTermHoles exty
  inty' <- fillTermHoles inty
  return (v, (pos, exty', inty'))

fillTermHoles :: TermMappable a => a -> SemChecker a
fillTermHoles = traverseTerm tty texp tloc trng
  where tty (TypeHole Nothing) = TypeHoleJ <$> genUVar
        tty (NoisyTypeHole pos) = do v <- genUVar
                                     recordNoisyHole v pos
                                     return $ TypeHoleJ v
        tty (TypedefType ty v) = return $ TypedefType (TypeHole Nothing) v -- don't want to fill type of typedef yet
        tty ty = return ty

        texp (Hole pos Nothing) = HoleJ pos <$> genUVar
        texp (NoisyHole pos) = do v <- genUVar
                                  recordNoisyHole v pos
                                  return $ HoleJ pos v
        texp exp = return exp

        tloc (Ref ty v) = return $ Ref (TypeHole Nothing) v -- don't want to fill type of Refs yet
        tloc loc = return loc

        trng rng = return rng

alphaRenameTerms :: ScopedTraverser a => Tag SourcePos -> a -> SemChecker a
alphaRenameTerms = scopedTraverseTerm alphatr
  where alphatr = ScopedTraverserRec
                  { stTy = \pos -> return
                  , stEx = \pos x -> case x of
                      Specialize pos v cases dflt -> do mv' <- lookupSym v
                                                        case mv' of
                                                          Just (_, v') ->
                                                            return $ Specialize pos v' cases dflt
                                                          Nothing -> do addError $ SemUnbound pos v
                                                                        return x
                      _ -> return x
                  , stLoc = \pos x -> case x of
                               Ref ty v -> do mv' <- lookupSym v
                                              case mv' of
                                                Just (_, v') -> return $ Ref ty v'
                                                Nothing -> do addError $ SemUnbound pos v
                                                              return x
                               _ -> return x
                  , stRng = \pos -> return
                  , stScope = \v pos withv -> withNewScope $
                                              do v' <- gensym v
                                                 mbinding <- addNewLocalBinding pos v v'
                                                 when (isJust mbinding) $
                                                   addError $ SemRebound pos v
                                                 withv v'
                  }

concretizeApps :: TermMappable a => a -> SemChecker a
concretizeApps = traverseTerm tty texp tloc trng
  where tty = return
        texp exp@(App pos fn@(Get _ (Ref _ f)) args) = do
          mf <- lookupGlobalType f
          case mf of
            Just (FnType ft) -> ConcreteApp pos fn <$> matchArgs pos args ft <*> return (TypeHole Nothing)
            Just _ -> do addError $ SemError pos "Cannot call non-function."
                         return exp
            Nothing -> do addError $ SemError pos "No such global function."
                          return exp
        texp exp@(App pos _ _) = do addError $ SemError pos "Cannot call expression."
                                    return exp
        texp exp = return exp

        tloc = return
        trng = return

globalCheckTypedefs :: SemChecker ()
globalCheckTypedefs = do
  defbs <- M.elems . globalBindings <$> get
  mapM_ doCheck defbs
  where doCheck defb = do
          let pos = bindingPos defb
          case definition defb of
            FunctionDef mexp ft -> do funTypeCheckTypedefs pos ft
                                      mapM_ (checkTypedefs pos) mexp
            ValueDef mexp ty -> do checkTypedefs pos ty
                                   mapM_ (checkTypedefs pos) mexp
            StructDef members -> structMemberCheckTypedefs members
            TypeDef ty -> checkTypedefs pos ty
            InlineCDef {} -> return ()

funTypeCheckTypedefs :: Tag SourcePos -> FunctionType -> SemChecker ()
funTypeCheckTypedefs pos (FnT args mva rty) = do
  forM_ args $ \(vpos, v, req, dir, vty) -> do
    checkTypedefs vpos vty
  checkTypedefs pos rty

structMemberCheckTypedefs :: [StructMember] -> SemChecker ()
structMemberCheckTypedefs members = forM_ members $ \(v, (pos, exty, inty)) -> do
  checkTypedefs pos exty
  checkTypedefs pos inty

checkTypedefs :: ScopedTraverser a => Tag SourcePos -> a -> SemChecker ()
checkTypedefs pos x = scopedTraverseTerm tr pos x >> return ()
  where tr = ScopedTraverserRec
             { stTy = \pos x -> case x of
                 TypedefType _ v -> do
                   mvdefb <- lookupGlobalBinding v
                   case mvdefb of
                     Just vdefb -> case definition vdefb of
                       StructDef {} -> return x
                       TypeDef {} -> return x
                       _ -> do addError $
                                 SemError pos $ "Identifier '" ++ v ++ "' does not refer to struct or typedef."
                               return x
                     Nothing -> do addError $ SemUnboundType pos v
                                   return x
                 _ -> return x
             , stEx = const return
             , stLoc = const return
             , stRng = const return
             , stScope = \v pos withv -> withv v
             }

-- | Match the arguments with the formal parameters for making a
-- ConcreteApp.  Note that this expects the effective type of the
-- function (i.e., the one where a complex return value is a pointer
-- argument).
matchArgs :: Tag SourcePos -> [Arg CExpr] -> FunctionType -> SemChecker [CExpr]
matchArgs pos args (FnT fargs mva _) = matchArgs' 1 args fargs
  where
    -- A passed argument matches a required argument
    matchArgs' i (Arg d1 x : xs) ((vpos, v, True, d0, ty) : fxs)
      = do when (d1 /= d0) $ addError $ SemError (MergeTags [pos,vpos]) $
             "Expecting " ++ dirName d0 ++ "-argument in position " ++ show i ++ "."
           (x :) <$> matchArgs' (1 + i) xs fxs
    -- An omitted implicit argument is filled with a value hole
    matchArgs' i xs@(Arg {} : _) ((vpos, v, False, _, ty) : fxs) = addImplicit i v ty xs fxs
    matchArgs' i [] ((vpos, v, False, _, ty) : fxs) = addImplicit i v ty [] fxs
    -- (error) An implicit argument where a required argument is expected
    matchArgs' i (ImpArg x : xs) ((vpos, v, True, dir, ty) : fxs) = do
      addError $ SemError (MergeTags [pos,vpos]) $
        "Unexpected implicit argument in position " ++ show i ++ "."
      matchArgs' (1 + i) xs ((vpos, v, True, dir, ty) : fxs)
    -- An implicit argument given where an implicit argument expected
    matchArgs' i (ImpArg x : xs) ((vpos, v, False, _, ty) : fxs) = (x :) <$> matchArgs' (1 + i) xs fxs
    -- (error) Fewer arguments than parameters
    matchArgs' i [] (fx : fxs) = do addError $ SemError pos $
                                      "Not enough arguments.  Given " ++ show i ++ "; " ++ validRange
                                    name <- genUVar -- try to recover for error message's sake
                                    (HoleJ pos name :) <$> matchArgs' i [] fxs
    -- Exactly the correct number of arguments
    matchArgs' i [] [] = return []
    matchArgs' i (Arg d x : xs) []
      | isJust mva  = do
          when (d /= fromJust mva) $ addError $ SemError pos $
            "Expecting " ++ dirName (fromJust mva) ++ "-argument as vararg."
          (x :) <$> matchArgs' (1 + i) xs []
    matchArgs' i (ImpArg x : xs) []
      | isJust mva = do addError $ SemError pos $
                          "Implicit argument not allowed as vararg."
                        return []
    matchArgs' i xs [] = do addError $ SemError pos $
                              "Too many arguments.  Given " ++ show i ++ ", " ++ validRange ++ "."
                            return []

    numReq = length $ filter (\(_, _, b, _, _) -> b) fargs
    validRange = "expecting " ++ show numReq ++ " required and " ++ show (length fargs - numReq) ++ " implicit arguments" ++ (if isJust mva then ", with any number of varargs" else "")

    addImplicit i v ty xs fxs = do name <- genUVarP v
                                   (HoleJ pos name :) <$> matchArgs' i xs fxs

    dirName ArgIn = "in"
    dirName ArgOut = "out"
    dirName ArgInOut = "inout"

-- | The unifier does not check type inequalities (like "float storage
-- contains int"). We check them here.  We also check that all holes
-- have been filled.
topVerifyStorage :: [DefBinding] -> SemChecker ()
topVerifyStorage dbs = mapM_ verifyStorageDefBinding dbs

verifyStorageDefBinding :: DefBinding -> SemChecker ()
verifyStorageDefBinding db = case definition db of
  FunctionDef mexp (FnT args mva retty) -> do
    forM_ args $ \(pos, v, b, dir, ty) -> do
      verifyStorage pos ty
    verifyStorage (bindingPos db) retty
    modify $ \state -> state { semRetType = retty }
    case mexp of
      Nothing -> return ()
      Just exp -> do verifyStorage (bindingPos db) exp
                     when (not $ typeCanHold retty (getType exp)) $
                       addError $ SemStorageError (bindingPos db) retty (getType exp)
  StructDef members -> do
    forM_ members $ \(v, (pos, exty, inty)) -> do
      verifyStorage pos exty
      verifyStorage pos inty
  ValueDef mexp ty -> do
    verifyStorage (bindingPos db) ty
    case mexp of
      Nothing -> return ()
      Just exp -> do verifyStorage (bindingPos db) exp
                     when (not $ typeCanHold ty (getType exp)) $
                       addError $ SemStorageError (bindingPos db) ty (getType exp)
  TypeDef ty -> return ()
  InlineCDef {} -> return ()

verifyStorage :: TermMappable a => Tag SourcePos -> a -> SemChecker ()
verifyStorage rpos = void . traverseTerm tty texp tloc trng
  where tty ty@(TypeHole {}) = do addError $ SemError rpos $ "Unresolved type hole " ++ show ty
                                  return ty
        tty ty = return ty

        texp ex@(Return pos _ v) = do verifyStorage pos v
                                      let vty = getType v
                                      retty <- semRetType <$> get
                                      when (not $ typeCanHold retty vty) $
                                        addError $ SemStorageError (getTag v) retty vty
                                      return ex
        texp ex@(Set pos loc v) = do verifyStorage pos loc
                                     verifyStorage pos v
                                     let lty = getLocType loc
                                         vty = getType v
                                     when (not $ typeCanHold lty vty) $
                                       addError $ SemStorageError (getTag v) lty vty
                                     return ex
        texp ex@(AssertType pos v ty) = do verifyStorage pos v
                                           verifyStorage pos ty
                                           let vty = getType v
                                           when (not $ typeCanHold ty vty) $ -- TODO is typeCanHold correct?
                                             addError $ SemStorageError pos ty vty
                                           return ex
        texp ex@(Hole pos _) = do addError $ SemError pos $ "Unresolved hole."
                                  return ex
        texp ex = return ex

        tloc = return
        trng = return
