{-# LANGUAGE UndecidableInstances #-}

module B9.Dsl.Interpreter where

import B9.B9IO
import B9.Dsl.Core
import B9.DynMap as DynMap
import Control.Lens hiding (from, (<.>))
import Control.Monad.State
import Data.Graph as Graph
import qualified Data.Map as Map hiding (null)
import Data.Singletons
import Data.Tree as Tree
import Control.Monad.Free (foldFree)
import Data.Foldable (sequenceA_)

-- * DSL Interpreter
-- | The monad transformer used to /compile/ a 'BuildPlanT'
newtype BuildPlan a =
  BuildPlan {runBuildPlan :: State Ctx a}
  deriving (Functor,Applicative,Monad,MonadState Ctx)

-- | The internal state of the 'BuildPlan' monad
data Ctx =
  Ctx {_nextVertex :: Vertex
      ,_hToV :: Map.Map SomeHandle Vertex
      ,_vToH :: Map.Map Vertex SomeHandle
      ,_dependencies :: [Edge]
      ,_builderMap :: BuilderMap
      ,_generatorMap :: Map.Map SomeHandle Generator}

instance Default Ctx where
  def = Ctx 0 def def [] DynMap.empty def

type BuilderMap = DynMap.DynMap "builders"

type ArtifactMap = DynMap.DynMap "artifacts"

type BuilderCtx k = [ArtifactMap -> (BuilderT IoProgram k ())]

type Generator = (ArtifactMap,BuilderMap) -> IoProgram (ArtifactMap,BuilderMap)

type instance DynMap.DynMapValue "builders" k = BuilderCtx k

type instance DynMap.DynMapValue "artifacts" k =
     Artifact IoProgram k

makeLenses ''Ctx

-- | Interpret a 'ProgramT' into a sequence of actions of a monad @m@.
interpret
  :: BuildPlanT IoProgram a -> BuildPlan a
interpret = foldFree go
  where go
          :: BuildStep IoProgram x -> BuildPlan x
        go (Create initialParameter k) =
          do h <-
               allocHandle initialParameter
                           (show initialParameter)
             putBuilderT h
                         [const (initialiseBuilder initialParameter)]
             generatorMap . at (SomeHandle h) ?= mkGenerator h
             return $ k h
        go (Apply handle action pureArg next) =
          do addBuilderT handle
                         [const (buildAction action pureArg)]
             return next
        go (Bind destinationHandle action sourceHandle next) =
          do sourceHandle --> destinationHandle
             addBuilderT
               destinationHandle
               [buildAction action . fromJust .
                DynMap.lookup (handleKey sourceHandle)]
             return next

-- | Create a unique key for 'ArtifactMap' and 'BuilderMap' from a handle.
handleKey :: Handle a -> DynMap.Key a
handleKey = DynMap.KeyFromProxy

-- | Create a 'Generator' for a 'Handle'.
mkGenerator :: (IsBuilder IoProgram a)
            => Handle a -> Generator
mkGenerator handle (artifactMapIn,builderMapIn) =
  do let key = handleKey handle
         builder =
           sequenceA_ $ map ($ artifactMapIn) $ join $ maybeToList $
           DynMap.lookup key builderMapIn
     artifact <- buildArtifact builder
     let artifactMapOut = DynMap.insert key artifact artifactMapIn
         builderMapOut = DynMap.delete key builderMapIn
     return (artifactMapOut,builderMapOut)

-- | * Builder and Artifact accessors
putBuilderT :: (Typeable b,b ~ BuilderCtx a)
            => Handle a -> b -> BuildPlan ()
putBuilderT handle b =
  builderMap %=
  DynMap.insert (handleKey handle)
                b

addBuilderT :: (Typeable b,b ~ BuilderCtx a)
            => Handle a -> b -> BuildPlan ()
addBuilderT handle b =
  builderMap %=
  DynMap.insertWith (++)
                    (handleKey handle)
                    b

-- | Create a new unique handle and store it in the state.
allocHandle
  :: Show (Proxy a)
  => p ignored a -> String -> BuildPlan (Handle a)
allocHandle sa str =
  do let toProxy2 :: p x y -> Proxy y
         toProxy2 _ = Proxy
     v <- addVertex
     let h =
           formatHandleP v
                         (toProxy2 sa)
                         str
     void $ storeHandle h v
     return h

-- | Add a handle to the vertex <-> handle maps in the state and return the
-- existential 'SomeHandle' that was stored in place of the polymorphic 'Handle
-- a'.
storeHandle
  :: Handle a -> Vertex -> BuildPlan SomeHandle
storeHandle h v =
  do let h' = SomeHandle h
     hToV . at h' ?= v
     vToH . at v ?= h'
     return h'

-- | Return a new and unique vertex (i.e. artifact id)
addVertex :: BuildPlan Vertex
addVertex =
  do v <- use nextVertex
     nextVertex += 1
     return v

-- | Generate a handle with formatted title
formatHandleP
  :: Show (p a)
  => Vertex -> p a -> String -> Handle a
formatHandleP v sa str =
  mkHandleP sa
            (if str == ""
                then show v
                else str ++ "-" ++ show v)

-- | Generate a handle with formatted title
formatHandleS
  :: (SingKind ('KProxy :: KProxy k),Show (Demote (a :: k)))
  => Vertex -> Sing a -> String -> Handle a
formatHandleS v sa str =
  mkHandleS sa
            (if str == ""
                then show v
                else str ++ "-" ++ show v)

-- | Add a dependency of one resource to another: @addDependency x y@ means
-- first build @x@ then @y@.
addDependency
  :: Handle a -> Handle b -> BuildPlan ()
addDependency = (-->)

-- | An alias for 'addDependency': @x --> y@ means @addDependency x y@ - i.e.
-- first build @x@ then @y@.
(-->)
  :: Handle a -> Handle b -> BuildPlan ()
h --> h' =
  do Just v <- lookupVertex h
     Just v' <- lookupVertex h'
     dependencies <>= [(v,v')]

-- | Return the vertex of a handle.
lookupVertex
  :: Handle a -> BuildPlan (Maybe Vertex)
lookupVertex h = use (hToV . at (SomeHandle h))

-- * Execution of the interpreter
-- | Compose all build steps into an 'IoProgram', with all build actions
-- executed in the order determined by the data-dependencies between buildsteps.
execBuildPlan :: BuildPlan a -> IoProgram (a, ArtifactMap)
execBuildPlan di =
  let ((a,depGraph),ctx) =
        runState (runBuildPlan ((,) <$> di <*> dependencyGraph)) def
      orderedVertices = maybe [0 .. _nextVertex ctx - 1] topSort depGraph
      vToG =
        Map.map (flip Map.lookup (_generatorMap ctx))
                (_vToH ctx)
      builders = catMaybes $ map (join . flip Map.lookup vToG) orderedVertices
  in do (artifactsOut,_builderOut) <-
          foldr (=<<) (return (DynMap.empty,_builderMap ctx)) builders
        return (a, artifactsOut)

testDi =
  execBuildPlan $ interpret $
    do t1 <- createFrom (FromPureValue "test1")
       t2 <- createFrom (FromPureValue "test2")
       bindTo t1 AppendPure t2
       applyTo t2 AppendPure " 222 "
       applyTo t1 AppendPure " 333 "


-- | Generate a graph from the artifact dependencies in the compiler context.
dependencyGraph :: BuildPlan (Maybe Graph)
dependencyGraph =
  do maxVertex <- use nextVertex
     if maxVertex > 0
        then do deps <- use dependencies
                return (Just (buildG (0,maxVertex - 1) deps))
        else return Nothing

-- * Debugging and tracing support
-- | Show the dependency graph from the compiler context.
printDependencyGraph
  :: Graph -> Map.Map Vertex SomeHandle -> String
printDependencyGraph g handles =
  unlines ("digraph artifactDependencyGraph {" :
           fmap (printEdge handles)
                (edges g) ++
           "}" :
           "Dependency forest:" :
           Tree.drawForest (fmap (printVertex handles) <$> dff g) :
           "Build order:" :
           (printVertex handles <$> topSort g))

-- | Convert an edge to a formatted string
printEdge
  :: Map.Map Vertex SomeHandle -> Edge -> String
printEdge handles (u,v) =
  printf "  %s   ->    %s"
         (show (printVertex handles u))
         (show (printVertex handles v))

-- | Convert a vertex to a formatted string
printVertex
  :: Map.Map Vertex SomeHandle -> Vertex -> String
printVertex handles v =
  printf "%s(%d)" (printSomeHandle (Map.lookup v handles)) v

-- | Convert maybe a handle to a string
printSomeHandle :: Maybe SomeHandle -> String
printSomeHandle (Just (SomeHandle h)) = show h
printSomeHandle Nothing = "??error??"
