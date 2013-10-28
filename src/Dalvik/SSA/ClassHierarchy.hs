module Dalvik.SSA.ClassHierarchy (
  ClassHierarchy,
  classHierarchy,
  superclass,
  definition,
  superclassDef,
  subclasses,
  allSubclasses,
  implementations,
  allImplementations,
  resolveMethodRef,
  virtualDispatch,
  anyTarget,
  implementationsOf
  ) where

import Control.Concurrent.MVar as MV
import Control.Monad ( foldM )
import qualified Data.List as L
import Data.HashMap.Strict ( HashMap )
import qualified Data.HashMap.Strict as HM
import Data.Maybe ( fromMaybe, mapMaybe )
import Data.Set ( Set )
import qualified Data.Set as S
import System.IO.Unsafe ( unsafePerformIO )

import Dalvik.SSA

import Debug.Trace
debug = flip trace

data ClassHierarchy =
  ClassHierarchy { hierarchy      :: HashMap Type Type
                 , children       :: HashMap Type [Type]
                 , implementors   :: HashMap Type [Type]
                 , typeToClassMap :: HashMap Type Class
                 , simpleCache    :: MVar (HashMap (MethodRef, Type) (Maybe Method))
                 }
  deriving (Eq)

emptyClassHierarchy :: MVar (HashMap (MethodRef, Type) (Maybe Method))
                       -> ClassHierarchy
emptyClassHierarchy mv =
  ClassHierarchy { hierarchy = HM.empty
                 , children = HM.empty
                 , implementors = HM.empty
                 , typeToClassMap = HM.empty
                 , simpleCache = mv
                 }

-- | Perform a class hierarchy analysis
classHierarchy :: DexFile -> ClassHierarchy
classHierarchy df = unsafePerformIO $ do
  mv <- MV.newMVar HM.empty
  return $ foldr addClass (emptyClassHierarchy mv) $ dexClasses df

addClass :: Class -> ClassHierarchy -> ClassHierarchy
addClass klass ch =
  ch { hierarchy = case classParent klass of
          Nothing -> hierarchy ch
          Just parent -> HM.insert (classType klass) parent (hierarchy ch)
     , children = case classParent klass of
          Nothing -> children ch
          Just parent -> HM.insertWith (++) parent [classType klass] (children ch)
     , implementors =
         L.foldl' (\m i -> HM.insertWith (++) i [classType klass] m)
                  (implementors ch)
                  (classInterfaces klass)
     , typeToClassMap = HM.insert (classType klass) klass (typeToClassMap ch)
     }

-- | Get the parent of a type, if any
superclass :: ClassHierarchy -> Type -> Maybe Type
superclass ch t = HM.lookup t (hierarchy ch)

-- | Get any immediate subclasses of the given type
subclasses :: ClassHierarchy -> Type -> [Type]
subclasses ch t = fromMaybe [] $ HM.lookup t (children ch)

-- | Get all subclasses transitively of the given type
allSubclasses :: ClassHierarchy -> Type -> [Type]
allSubclasses ch = starClosure (subclasses ch)

-- | Get the types that implement the given interface directly
implementations :: ClassHierarchy -> Type -> [Type]
implementations ch t = fromMaybe [] $ HM.lookup t (implementors ch)

-- | Get the types implemented by the given interface or its subinterfaces
allImplementations :: ClassHierarchy -> Type -> [Type]
allImplementations ch t = imm ++ concatMap (allImplementations ch) imm
  where imm = implementations ch t

starClosure :: (a -> [a]) -> a -> [a]
starClosure f x = x : concatMap (starClosure f) (f x)

-- | Get the definition of the parent of a type, if any
superclassDef :: ClassHierarchy -> Type -> Maybe Class
superclassDef ch t = do
  pt <- superclass ch t
  definition ch pt

-- | Return the definition of the given class type if the definition
-- is available in this dex file.
definition :: ClassHierarchy -> Type -> Maybe Class
definition ch t = HM.lookup t (typeToClassMap ch)

-- | Given a type of a value and a reference to a method to be called
-- on that value, figure out which actual method will be invoked.
--
-- Note, only virtual methods are checked because direct method calls
-- do not need to be resolved.
resolveMethodRef :: ClassHierarchy -> Type -> MethodRef -> Maybe Method
resolveMethodRef ch t0 mref = unsafePerformIO $ go t0
  where
    go t = do
      sc <- MV.readMVar (simpleCache ch)
      case HM.lookup (mref, t) sc of
        Just res -> return res
        Nothing -> do
          let mm = do
                klass <- definition ch t
                L.find (matches mref) (classVirtualMethods klass)
          res <- case mm of
            Nothing -> maybe (return Nothing) go (superclass ch t)
            Just _ -> return mm
          MV.modifyMVar_ (simpleCache ch) $ \c ->
            return $ HM.insert (mref, t) res c
          return res

matches :: MethodRef -> Method -> Bool
matches mref m = methodRefName mref == methodName m &&
                   methodRefReturnType mref == methodReturnType m &&
                   methodRefParameterTypes mref == map parameterType ps
  where
    -- Irrefutable pattern match since we are only checking virtual
    -- methods and they all have a @this@ parameter that we need to
    -- ignore (since MethodRefs do not include @this@)
    _:ps = methodParameters m

virtualDispatch :: ClassHierarchy
                   -> Instruction -- ^ Invoke instruction
                   -> InvokeVirtualKind -- ^ Type of invocation
                   -> MethodRef -- ^ Method being invoked
                   -> Value -- ^ Receiver object
                   -> Set Method
virtualDispatch cha i ikind mref receiver
  | ikind == MethodInvokeSuper = maybe S.empty S.singleton $ do
    let bb = instructionBasicBlock i
        lmeth = basicBlockMethod bb
    pt <- superclass cha (classType (methodClass lmeth))
    resolveMethodRef cha pt mref
  | Just Parameter {} <- fromValue receiver =
    anyTarget cha ikind mref (valueType receiver)
  | Just MoveException {} <- fromValue (stripCasts receiver) =
    anyTarget cha ikind mref (valueType receiver)
  | otherwise = maybe S.empty S.singleton $ do
    resolveMethodRef cha (valueType receiver) mref

-- | Find all possible targets for a call to the given 'MethodRef'
-- from a value of the given 'Type'.
anyTarget :: ClassHierarchy -> InvokeVirtualKind -> MethodRef -> Type -> Set Method
anyTarget cha k mref t0 = unsafePerformIO $ go S.empty rootType
  where
    rootType = if k /= MethodInvokeSuper then t0 else fromMaybe t0 (superclass cha t0)
    go ms t = do
      let ms' = case resolveMethodRef cha t mref of
            Just m -> S.insert m ms
            Nothing -> ms
      foldM go ms' (subclasses cha t)

-- | Given a class (or interface) name and a method name, find all of
-- the 'Method's implementing that interface method.
--
-- Algorithm:
--
-- 1) Find all classes implementing the named interface (if any)
--
-- 2) Look up the name as if it were a class.
--
-- 3) These are the roots of the search; for each of these classes,
--    find all of the matching methods in the class (one or zero) and
--    then recursively look at all subclasses.
--
-- Note that this is a linear pass over all of the classes in the
-- hierarchy, and won't be cheap.
--
-- The 'MethodRef' is only used to get the method name and signature.
-- You could safely create one manually with a dummy 'methodRefId' and
-- 'methodRefClass' (since neither is consulted).
--
-- Only virtual methods are searched because there is no dispatch for
-- direct methods.
implementationsOf :: ClassHierarchy -> ClassName -> MethodRef -> [Method]
implementationsOf ch klassName mref =
  foldr go [] rootClasses `debug` show rootClasses
  where
    t0 = ReferenceType klassName
    allClasses = HM.elems (typeToClassMap ch)
    classesImplementing =
      [c | c <- allClasses, t0 `elem` classInterfaces c]
    mnamedClass = HM.lookup t0 (typeToClassMap ch)
    rootClasses = maybe classesImplementing (:classesImplementing) mnamedClass
    go klass acc =
      let ms = filter (matches mref) $ classVirtualMethods klass
          subs = mapMaybe (definition ch) $ subclasses ch (classType klass)
      in foldr go (ms ++ acc) subs
