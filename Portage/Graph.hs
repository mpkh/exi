{-| 
    Maintainer  :  Andres Loeh <kosmikus@gentoo.org>
    Stability   :  provisional
    Portability :  haskell98

    Generation of dependency graph.
-}

module Portage.Graph
  where

import Data.Map (Map)
import qualified Data.Map as M
import Data.List
import Data.Maybe (fromJust, isJust, listToMaybe, maybeToList)
import Data.Graph.Inductive hiding (version, Graph(), NodeMap())
import Control.Monad.Identity
import Control.Monad.State

import Portage.Tree
import Portage.Match
import Portage.Dependency hiding (getDepAtom)
import Portage.Ebuild (Variant(..), Ebuild(iuse), EbuildMeta(..), EbuildOrigin(..), TreeLocation(..), Mask(..), Link(..), pvs)
import qualified Portage.Ebuild as E
import Portage.Version
import Portage.Package
import Portage.PortageConfig
import Portage.Config
import Portage.Use
import Portage.Strategy

findVersions :: Tree -> DepAtom -> [Variant]
findVersions = flip matchDepAtomTree

showVariant :: Config -> Variant -> String
showVariant cfg (Variant m e)  =  showPV (pv m) ++ showSlot (E.slot e) ++ showLocation cfg (location m) 
                                  ++ " " ++ unwords (map showMasked (masked m))
                                  ++ " " ++ concatMap hardMask (masked m) ++ unwords (diffUse (mergeUse (use cfg) (locuse m)) (iuse e))

showLocation :: Config -> TreeLocation -> String
showLocation c Installed          =  " (installed)"
showLocation c (Provided f)       =  " (provided in " ++ f ++ ")"
showLocation c (PortageTree t l)  =  showLink l ++
                                     if portDir c == t then "" else " [" ++ t ++ "]"

showLink :: Link -> String
showLink NoLink     = ""
showLink (Linked v) = " [" ++ showVersion (verPV . pv . meta $ v) ++ "]"

showTreeLocation :: TreeLocation -> String
showTreeLocation Installed          =  "installed packages"
showTreeLocation (Provided f)       =  "provided packages from " ++ f
showTreeLocation (PortageTree t _)  =  t

hardMask :: Mask -> String
hardMask (HardMasked f r) = unlines r
hardMask _                = ""

showMasked :: Mask -> String
showMasked (KeywordMasked xs) = "(masked by keyword: " ++ show xs ++ ")"
showMasked (HardMasked f r) = "(hardmasked in " ++ f ++ ")"
showMasked (ProfileMasked f) = "(excluded from profile in " ++ f ++")"
showMasked (Shadowed t) = "(shadowed by " ++ showTreeLocation t ++ ")"


-- x :: Graph -> DepString -> Graph
-- y :: Graph -> DepTerm -> Graph
-- z :: Graph -> DepAtom -> Graph

type DGraph = Graph
type Graph = Gr [Action] DepType
data DepType = Depend        Bool DepAtom
             | RDepend       Bool DepAtom
             | PDepend       Bool DepAtom
             | Meta                        -- ^ meta-logic (e.g. build before available)
  deriving (Eq,Show)

data Action  =  Available    Variant
             |  Built        Variant
             |  Removed      Variant  -- ^ mainly for the future, reverse deps
             |  Top
             |  Bot

getVariant :: Action -> Maybe Variant
getVariant (Available v)  =  Just v
getVariant (Built v)      =  Just v
getVariant (Removed v)    =  Just v
getVariant _              =  Nothing

getDepAtom :: DepType -> Maybe DepAtom
getDepAtom (Depend _ a)   =  Just a
getDepAtom (RDepend _ a)  =  Just a
getDepAtom (PDepend _ a)  =  Just a
getDepAtom _              =  Nothing

-- | More efficient comparison for actions.
instance Eq Action where
  (Available    v1)  ==  (Available    v2)  =  pv (meta v1) == pv (meta v2)
  (Built        v1)  ==  (Built        v2)  =  pv (meta v1) == pv (meta v2)
  (Removed      v1)  ==  (Removed      v2)  =  pv (meta v1) == pv (meta v2)
  Top                ==  Top                =  True
  Bot                ==  Bot                =  True
  _                  ==  _                  =  False

instance Show Action where
  show (Available    v) = "A  " ++ showPV (pv (meta v))
  show (Built        v) = "B  " ++ showPV (pv (meta v))
  show (Removed      v) = "D  " ++ showPV (pv (meta v))
  show Top              = "/"
  show Bot              = "_"

showAction :: Config -> Action -> String
showAction c (Available    v) = "A  " ++ showVariant c v
showAction c (Built        v) = "B  " ++ showVariant c v
showAction c (Removed      v) = "D  " ++ showVariant c v
showAction c Top              = "/"
showAction c Bot              = "_"

isActive :: Variant -> Map PS PV -> Bool
isActive v m =  case M.lookup (extractPS . pvs $ v) m of
                  Nothing   ->  False
                  Just pv'  ->  (pv . meta $ v) == pv'

activate :: Variant -> GG ()
activate v = 
    do  a   <-  gets active
        ls  <-  gets labels
        let ps' = extractPS . pvs $ v
        case M.lookup (extractPS . pvs $ v) a of
          Nothing   ->  do
                            let pv' = pv . meta $ v
                            modify (\s -> s { active = M.insert ps' pv' a })
                            modifyGraph ( insEdge (top, available (ls M.! pv'), Meta) )
          Just pv'
            | pv' == (pv . meta $ v)  ->  return ()
            | otherwise               ->  fail "depgraph slot conflict"

data DepState =  DepState
                   {
                      pconfig   ::  PortageConfig,
                      dlocuse   ::  [UseFlag],
                      graph     ::  Graph,
                      labels    ::  Map PV NodeMap,
                      active    ::  Map PS PV,
                      counter   ::  Int,
                      callback  ::  Callback
                   }

type Callback = DepAtom -> NodeMap -> GG [Progress]
type NodeMap = (Int,Int,Int)

available, built, removed :: NodeMap -> Int
available  (b,a,r) = a
built      (b,a,r) = b
removed    (b,a,r) = r

top = 0
bot = 1


depend :: NodeMap -> DepAtom -> NodeMap -> GG [Progress]
depend source da target
    | blocking da =
        do
            modifyGraph (insEdges [  (built target,built source,Depend True da) ])
            return [AddEdge (built target) (built source) (Depend True da)]
    | otherwise =
        do
            modifyGraph (insEdges [  (built source,available target,Depend False da),
                                     (removed target,built source,Depend True da) ])
            return [AddEdge (built source) (available target) (Depend False da)]

rdepend :: NodeMap -> DepAtom -> NodeMap -> GG [Progress]
rdepend source da target
    | blocking da =
        do
           modifyGraph (insEdges [  (built target,removed source,RDepend True da) ])
           return [AddEdge (built target) (removed source) (RDepend True da)]
    | otherwise =
        do
           modifyGraph (insEdges [  (available source,available target,RDepend False da),
                                    (removed target,removed source,RDepend True da) ])
           return [AddEdge (available source) (available target) (RDepend False da)]

-- | Like 'rdepend' really, except for the 'DepType'. Could be unified.
pdepend :: NodeMap -> DepAtom -> NodeMap -> GG [Progress]
pdepend source da target
    | blocking da =
        do
           modifyGraph (insEdges [  (built target,removed source,PDepend True da) ])
           return [AddEdge (built target) (removed source) (PDepend True da)]
    | otherwise =
        do
           modifyGraph (insEdges [  (available source,available target,PDepend False da),
                                    (removed target,removed source,PDepend True da) ])
           return [AddEdge (available source) (available target) (PDepend False da)]

data Progress =  LookAtEbuild  PV EbuildOrigin
              |  AddEdge       Node Node DepType
              |  Message       String
  deriving (Eq,Show)

-- | Graph generation monad.
type GG = State DepState

-- | Modify the graph within the monad.
modifyGraph :: (Graph -> Graph) -> GG ()
modifyGraph f = modify (\s -> s { graph = f (graph s) })

-- | Modify the counter within the monad.
stepCounter :: Int -> GG Int
stepCounter n = do  c <- gets counter
                    modify (\s -> s { counter = n + counter s })
                    return c

-- | Create a new node within the monad.
newNode :: GG Node
newNode =
    do  g <- gets graph
        return (head $ newNodes 1 g)

-- | Insert a set of new nodes into the graph, if it doesn't exist yet.
insNewNode :: Variant -> Bool -> GG NodeMap
insNewNode v a =
    do  ls <- gets labels
        case M.lookup (pv . meta $ v) ls of
          Nothing | a && (E.isAvailable . location $ meta v)  ->  insAvailableHistory v
                  | otherwise                                 ->  
                      case location . meta $ v of
                        PortageTree _ (Linked v') -> insUpgradeHistory v' v
                        _                         -> insInstallHistory v
          Just nm -> return nm

insAvailableHistory :: Variant -> GG NodeMap
insAvailableHistory v =
    do  n <- stepCounter 2
        let  a    =  n
             r    =  n + 1
             ps'  =  extractPS (pvs v)
             pv'  =  pv . meta $ v
             nm   =  (a,a,r)
        registerNode pv' nm
        modifyGraph (  insEdges [ (r,a,Meta),
                                  (bot,a,Meta),
                                  (r,top,Meta) ] .
                       insNodes [ (a,[Available v]),
                                  (r,[Removed v]) ])
        return nm

-- | An upgrade history can also be a downgrade history, or even a recompilation
--   history. The only common element is that one variant of one package is
--   replaced by another variant of the same package.
insUpgradeHistory :: Variant -> Variant -> GG NodeMap
insUpgradeHistory v v' =
    do  n <- stepCounter 4
        let  a    =  n
             b'   =  n + 1
             r    =  b'
             a'   =  n + 2
             r'   =  n + 3
             nm   =  (a,a,r)
             nm'  =  (b',a',r')
        registerNode (pv . meta $ v) nm
        registerNode (pv . meta $ v') nm'
        modifyGraph (  insEdges [ (r',a',Meta),
                                  (a',b',Meta),
                                  (r,a,Meta),
                                  (bot,a,Meta),
                                  (r',top,Meta) ] .
                       insNodes [ (b',[Built v',Removed v]),
                                  (a',[Available v']),
                                  (r',[Removed v']),
                                  (a,[Available v]) ])
        return nm'

insInstallHistory :: Variant -> GG NodeMap
insInstallHistory v =
    do  n <- stepCounter 3
        let  b    =  n
             a    =  n + 1
             r    =  n + 2
             pv'  =  pv . meta $ v
             nm   =  (b,a,r)
        registerNode pv' nm
        modifyGraph (  insEdges [ (r,a,Meta),
                                  (a,b,Meta),
                                  (b,bot,Meta),
                                  (r,top,Meta) ] .
                       insNodes [ (b,[Built v]),
                                  (a,[Available v]),
                                  (r,[Removed v]) ])
        return nm

registerNode :: PV -> NodeMap -> GG ()
registerNode pv nm = modify (\s -> s { labels = M.insert pv nm (labels s) })

-- | Builds a graph for an uninterpreted dependency string,
--   i.e., a dependency string containing USE flags.
buildGraphForUDepString :: DepString -> GG [Progress]
buildGraphForUDepString ds =
    do
        luse  <-  gets dlocuse
        buildGraphForDepString (interpretDepString luse ds)

-- | Builds a graph for the whole dependency string,
--   by processing each term separately.
--   Precondition: dependency string must be interpreted,
--   without USE flags.
buildGraphForDepString :: DepString -> GG [Progress]
buildGraphForDepString ds = fmap concat (mapM buildGraphForDepTerm ds)

-- | Builds a graph for a single term.
--   Precondition: dependency string must be interpreted,
--   without USE flags.
--   If it is an atom, just delegate.
--   If it is a use-qualified thing, check the USE flag and delegate.
--   If it is an or-dependency, ...
buildGraphForDepTerm :: DepTerm -> GG [Progress]
buildGraphForDepTerm dt =
    do  
        pc    <-  gets pconfig
        case resolveVirtuals pc dt of
          Plain d                   ->  buildGraphForDepAtom d
          And ds                    ->  buildGraphForDepString ds
          Or ds                     ->  buildGraphForOr ds

resolveVirtuals :: PortageConfig -> DepTerm -> DepTerm
resolveVirtuals pc (Plain d)  =  maybe (Plain d) id (virtuals pc d)
resolveVirtuals _  dt         =  dt

buildGraphForOr :: DepString -> GG [Progress]
buildGraphForOr []         =  return []  -- strange case, empty OR, but ok
buildGraphForOr ds@(dt:_)  =
    do
        pc    <-  gets pconfig
        case findInstalled pc ds of
          Nothing   ->  do  p <- buildGraphForDepTerm dt  -- default
                            return $ [Message $ "|| (" ++ show ds ++ ")) resolved to default"] ++ p
          Just dt'  ->  do  
                            p <- buildGraphForDepTerm dt'  -- installed
                            return $ [Message $ "|| (" ++ show ds ++ ")) resolved to available: " ++ show dt'] ++ p
  where
    findInstalled :: PortageConfig -> DepString -> Maybe DepTerm
    findInstalled pc = find (isInstalledTerm . resolveVirtuals pc)
      where
        isInstalledTerm :: DepTerm -> Bool
        isInstalledTerm (Or ds)    =  any isInstalledTerm ds
        isInstalledTerm (And ds)   =  all isInstalledTerm ds
        isInstalledTerm (Plain d)  =  isInstalled pc d

-- Critical case for OR-dependencies:
-- || ( ( a b ) c )
-- genone says in #gentoo-portage:
-- if nothing is installed it selects a+b, 
-- if only a and/or b is installed it selects a+b, 
-- if c and one of a or b is installed it selects c

isInstalled :: PortageConfig -> DepAtom -> Bool
isInstalled pc da =
    let  p  =  pFromDepAtom da
         t  =  itree pc
    in   case selectInstalled p (findVersions t da) of
           Accept v  ->  True
           _         ->  False

withLocUse :: [UseFlag] -> GG a -> GG a
withLocUse luse' g =
    do
        luse <- gets dlocuse
        modify (\s -> s { dlocuse = luse' })
        r <- g
        modify (\s -> s { dlocuse = luse })
        return r

withCallback :: Callback -> GG a -> GG a
withCallback cb' g =
    do
        cb <- gets callback
        modify (\s -> s { callback = cb' })
        r <- g
        modify (\s -> s { callback = cb })
        return r

buildGraphForDepAtom :: DepAtom -> GG [Progress]
buildGraphForDepAtom da
    | blocking da =
        do  -- for blocking dependencies, we have to consider all matching versions
            pc  <-  gets pconfig
            let  s  =  strategy pc
                 t  =  itree pc
            cb  <-  gets callback
            p   <-  mapM
                      (\v -> do
                                 n <- insNewNode v (sstop s v)
                                 p' <- cb da n
                                 return (LookAtEbuild (pv (meta v)) (origin (meta v)) : p'))
                      (findVersions t (unblock da))
            return ((Message $ "blocker " ++ show da) : concat p)
    | otherwise =
        do  pc  <-  gets pconfig
            g   <-  gets graph
            ls  <-  gets labels
            a   <-  gets active
            let  s  =  strategy pc
                 t  =  itree pc
                 p  =  pFromDepAtom da
            case sselect s p (findVersions t da) of
              Reject f -> return []  -- fail (show f)
              Accept v@(Variant m e)  ->  
                let  avail      =  E.isAvailable (location m)  -- installed or provided?
                     already    =  isActive v a
                     stop       =  avail && sstop s v 
                                     -- if it's an installed ebuild, we can decide to stop here!
                in                 let  rdeps    =  E.rdepend  e
                                        deps     =  E.depend   e
                                        pdeps    =  E.pdepend  e
                                        luse     =  mergeUse (use (config pc)) (locuse m)
                                   in   -- set new local USE context
                                        withLocUse luse $
                                        do
                                            -- insert nodes for v, and activate
                                            n <- insNewNode v stop
                                            activate v
                                            -- insert edges according to current state
                                            cb <- gets callback
                                            p0 <- cb da n
                                            if already || stop
                                              then return ([LookAtEbuild (pv (meta v)) (origin (meta v))] ++ p0)
                                              else do
                                                       -- add deps to graph
                                                       p1 <- withCallback (depend n) $ buildGraphForUDepString deps
                                                       -- add rdeps to graph
                                                       p2 <- withCallback (rdepend n) $ buildGraphForUDepString rdeps
                                                       -- add pdeps to graph
                                                       p3 <- withCallback (pdepend n) $ buildGraphForUDepString pdeps
                                                       return ([LookAtEbuild (pv (meta v)) (origin (meta v))] ++ p0 ++ p1 ++ p2 ++ p3)


isAvailable :: Action -> Maybe Variant
isAvailable (Available v)  =  Just v
isAvailable _              =  Nothing

isAvailableNode :: Graph -> Int -> Maybe Variant
isAvailableNode g = msum . map isAvailable . fromJust . lab g

getVariantsNode :: Graph -> Int -> [Variant]
getVariantsNode g = concatMap (maybeToList . getVariant) . fromJust . lab g

isUpgradeNode :: Graph -> Node -> Maybe (Node,Variant,Node,Variant)
isUpgradeNode g n =  listToMaybe $
                     [ (n,v',a,v) |  let va' = isAvailableNode g n, isJust va', let (Just v') = va',
                                     (_,t,Meta) <- out g n, (_,a,Meta) <- out g t,
                                     let va = isAvailableNode g a, isJust va, let (Just v) = va ]

-- Types of cycles:
-- * Bootstrap cycle. A cycle which wants to recursively update itself, but a
--   version is already installed (happens if an upgrade strategy always selects
--   the most recent version). If we have an Upgrade-history, and incoming dependencies
--   on the newer version from within the cycle, we can redirect these dependencies
--   to the old version.
-- * PDEPEND cycle. All cycles that contain PDEPEND edges. For an Available-type node
--   with an outgoing PDEPEND, we redirect incoming DEPENDs and RDEPENDs from within 
--   the cycle to the Built state.
-- * Self-blockers. We just drop them, but with a headache.
-- This is currently very fragile w.r.t. ordering of the resolutions.
resolveCycle :: [Node] -> GG (Bool,[Progress])
resolveCycle cnodes = 
    do  g <- gets graph
        let cedges = zipWith findEdge  (map (out g) cnodes)
                                       (tail cnodes ++ [head cnodes])
        sumR $ 
                   map resolvePDependCycle (filter isPDependEdge cedges)
               ++  map resolveSelfBlockCycle (filter (\x -> isBlockingDependEdge x || isBlockingRDependEdge x) cedges)
               ++ (case detectBootstrapCycle g cnodes of
                    Just (a',v',a,v)  ->  [resolveBootstrapCycle a' v' a v]
                    Nothing           ->  [])
  where
    detectBootstrapCycle :: Graph -> [Node] -> Maybe (Node,Variant,Node,Variant)
    detectBootstrapCycle g ns = msum (map (isUpgradeNode g) ns)

    resolveBootstrapCycle :: Node -> Variant -> Node -> Variant -> GG (Bool,[Progress])
    resolveBootstrapCycle a' v' a v =
        do
            g <- gets graph
            let incoming  =  filter  (\e@(s',_,d') ->  s' `elem` cnodes &&
                                                       (isJust . getDepAtom $ d') &&
                                                       matchDepAtomVariant (fromJust . getDepAtom $ d') v &&
                                                       (isDependEdge e || isRDependEdge e))
                                     (inn g a')
            if null incoming
              then failR []
              else do  modifyGraph (  insEdges (map (\(s',_,d') -> (s',a,d')) incoming) .
                                      delEdges (map (\(s',t',_) -> (s',t')) incoming) )
                       succeedR [Message $ "Resolved bootstrap cycle at "  ++ (showPV . pv . meta $ v')
                                                                           ++ " (redirected " ++ show incoming ++ ")"]

    resolveSelfBlockCycle :: LEdge DepType -> GG (Bool,[Progress])
    resolveSelfBlockCycle (s,t,d) =
        do
            g <- gets graph
            case (getVariantsNode g s,getVariantsNode g t) of
              (vs,vs')     ->  let  vsi = intersect (map (pv . meta) vs) (map (pv . meta) vs')
                               in   if not . null $ vsi
                                      then  do  modifyGraph (delEdge (s,t))
                                                succeedR [Message $ "Resolved self-block cycle at " ++ (showPV $ head vsi)
                                                                                                    ++ " (redirected " ++ show (s,t,d) ++ ")"]
                                      else  failR []
 
    resolvePDependCycle :: LEdge DepType -> GG (Bool,[Progress])
    resolvePDependCycle (s,t,d) =
        do
            ls <- gets labels
            g <- gets graph
            case isAvailableNode g s of
              Nothing  ->  failR []
              Just v   ->  do  let incoming = 
                                     filter  (\e@(s',_,_) ->  s' `elem` cnodes &&
                                                              (isDependEdge e || isRDependEdge e))
                                             (inn g s)
                               if null incoming
                                 then failR []
                                 else do  let pv'  =  pv . meta $ v
                                          let nm   =  ls M.! pv'
                                          modifyGraph (  insEdges (map (\(s',_,d') -> (s',built nm,d')) incoming) .
                                                         delEdges (map (\(s',t',_) -> (s',t')) incoming) )
                                          succeedR [Message $ "Resolved PDEPEND cycle at " ++ showPV pv' ++ " (redirected " ++ show incoming ++ ")" ]

(||.) :: GG (Bool,[a]) -> GG (Bool,[a]) -> GG (Bool,[a])
f ||. g = do  (b,r) <- f
              if b  then return (b,r)
                    else do  (c,r') <- g
                             return (c, r ++ r')

(&&.) :: GG (Bool,[a]) -> GG (Bool,[a]) -> GG (Bool,[a])
f &&. g = do  (b1,r1) <- f
              (b2,r2) <- g
              return (b1 || b2, r1 ++ r2)

succeedR :: [a] -> GG (Bool,[a])
succeedR ps = return (True,ps)

failR :: [a] -> GG (Bool,[a])
failR ps = return (False,ps)

sumR :: [GG (Bool,[a])] -> GG (Bool,[a])
sumR = foldr (||.) (failR [])

allR :: [GG (Bool,[a])] -> GG (Bool,[a])
allR = foldr (&&.) (failR [])

isPDependEdge :: LEdge DepType -> Bool
isPDependEdge  (_,_,PDepend False _)  =  True
isPDependEdge  _                      =  False

isDependEdge :: LEdge DepType -> Bool
isDependEdge   (_,_,Depend False _)   =  True
isDependEdge   _                      =  False

isRDependEdge :: LEdge DepType -> Bool
isRDependEdge  (_,_,RDepend False _)  =  True
isRDependEdge  _                      =  False

isBlockingDependEdge :: LEdge DepType -> Bool
isBlockingDependEdge   (_,_,Depend True da)   =  blocking da
isBlockingDependEdge   _                      =  False

isBlockingRDependEdge :: LEdge DepType -> Bool
isBlockingRDependEdge  (_,_,RDepend True da)  =  blocking da
isBlockingRDependEdge  _                      =  False

findEdge :: [LEdge b] -> Node -> LEdge b
findEdge es n = fromJust $ find (\(_,t,_) -> n == t) es

