{-|
    Maintainer  :  Andres Loeh <kosmikus@gentoo.org>
    Stability   :  provisional
    Portability :  haskell98

    The data structure that contains a portage tree.
-}

module Portage.Tree
  where

import System.IO
import System.IO.Unsafe
import System.Directory
import qualified Data.Map as M
import Data.Map (Map)
import Data.List

import Portage.Package
import Portage.Ebuild
import Portage.Eclass (Eclass, EclassMeta(EclassMeta))
import qualified Portage.Eclass as EC
import Portage.Version
import Portage.Config
import Portage.Utilities
import Portage.Constants
import Portage.Shell

data Tree =  Tree
               {
                  eclasses  ::  Map Eclass EclassMeta,
                  ebuilds   ::  Map Category (Map Package [Variant])
               }

-- | Utility function for maps. Updates a map but uses a default if
--   an updated key is not yet present.
updateWithDefault :: Ord k => (v -> Maybe v) -> k -> v -> Map k v -> Map k v
updateWithDefault f k d m =  let  m' = M.insertWith (curry snd) k d m  -- prefer the previous entry if present
                             in   M.update f k m'


-- | Create the tree of installed packages.
createInstalledTree  ::  Config           -- ^ portage configuration
                     ->  IO Tree
createInstalledTree cfg =
    do
        cats <- unsafeInterleaveIO $ getSubdirectories dbDir
        ebuilds' <- fmap M.fromList (mapM categoryEntries cats)
        return (Tree M.empty ebuilds')
  where
    categoryEntries :: Category -> IO (Category, Map Package [Variant])
    categoryEntries cat     =  do  
                                   ps <- unsafeInterleaveIO $ categoryMap cat
                                   return (cat, ps)

    categoryMap :: Category -> IO (Map Package [Variant])
    categoryMap cat         =  do
                                   pkgvers  <-  ifDirectoryExists getSubdirectories (dbDir ./. cat)
                                   let pvss  =  groupBy  (\(PV c1 p1 _) (PV c2 p2 _)
                                                            -> c1 == c2 && p1 == p2) .
                                                map (getPV . (cat ./.)) $
                                                pkgvers
                                   -- each of the sublists is non-empty
                                   fmap M.fromList (mapM packageEntries pvss)

    packageEntries  ::  [PV]      -- ^ must be nonempty
                    ->  IO (Package, [Variant])
    packageEntries pvs@(PV _ pkg _:_) =  
                               do
                                   es <- unsafeInterleaveIO $ mapM ebuildEntries pvs
                                   return (pkg, es)

    ebuildEntries :: PV -> IO Variant
    ebuildEntries pv@(PV cat pkg ver)
                            =  do
                                   c <- unsafeInterleaveIO $ getInstalledVariantFromDisk cfg pv
                                   return c


-- | Create a tree from an overlay.
createTree  ::  Config                     -- ^ portage configuration
            ->  FilePath                   -- ^ the portage tree
            ->  [Category]                 -- ^ the list of categories
            ->  Map Eclass EclassMeta      -- ^ final eclass map
            ->  IO Tree
createTree cfg pt cats ecs =  
    do
        eclasses' <- getEclasses
        ebuilds' <- fmap M.fromList (mapM categoryEntries cats)
        return (Tree eclasses' ebuilds')
  where
    getEclasses :: IO (Map Eclass EclassMeta)
    getEclasses             =  do
                                   eclasses <- fmap  (  map (\x -> take (length x - 7) x) .
                                                        filter (".eclass" `isSuffixOf`))
                                                     (ifDirectoryExists getDirectoryContents (eclassDir pt))
                                   fmap M.fromList (mapM eclassEntries eclasses)

    eclassEntries :: Eclass -> IO (Eclass, EclassMeta)
    eclassEntries eclass    =  do
                                   mtime <-  unsafeInterleaveIO $ 
                                             getMTime (eclassDir pt ./. (eclass ++ ".eclass"))
                                   return (eclass, EclassMeta pt mtime)

    categoryEntries :: Category -> IO (Category, Map Package [Variant])
    categoryEntries cat     =  do  
                                   ps <- unsafeInterleaveIO $ categoryMap cat
                                   return (cat, ps)

    categoryMap :: Category -> IO (Map Package [Variant])
    categoryMap cat         =  do
                                   pkgs <- ifDirectoryExists getSubdirectories (pt ./. cat)
                                   fmap M.fromList (mapM (packageEntries cat) pkgs)

    packageEntries :: Category -> Package -> IO (Package, [Variant])
    packageEntries cat pkg  =  do
                                   es <- unsafeInterleaveIO $ packageMap cat pkg
                                   return (pkg, es)

    packageMap :: Category -> Package -> IO [Variant]
    packageMap cat pkg      =  do
                                   ebuilds <- fmap  (  map (\x -> take (length x - 7) x) .
                                                       filter (".ebuild" `isSuffixOf`))
                                                    (getDirectoryContents (pt ./. cat ./. pkg))
                                   mapM (ebuildEntries cat pkg) ebuilds

    ebuildEntries :: Category -> Package -> String -> IO Variant
    ebuildEntries cat pkg ebuild
                            =  do
                                   let version          =  drop (length pkg + 1) ebuild
                                   let ver              =  getVersion version
                                   let pv               =  PV cat pkg ver
                                   let meta             =  EbuildMeta
                                                             {
                                                               pv        =  pv,
                                                               location  =  PortageTree pt,
                                                               masked    =  [],
                                                               locuse    =  [],
                                                               lockey    =  []
                                                             }
                                   c <- unsafeInterleaveIO $ getEbuildFromDisk cfg pt pv ecs
                                   return (Variant meta c)

-- | Combines two trees such that the second one is the overlay and has priority.
overlayTree :: Tree -> Tree -> Tree
overlayTree (Tree ec1 eb1) (Tree ec2 eb2) =  Tree  (overlayEclasses  ec1  ec2)
                                                   (overlayEbuilds   eb1  eb2)

overlayEclasses :: Map Eclass EclassMeta -> Map Eclass EclassMeta -> Map Eclass EclassMeta
overlayEclasses  =  M.unionWith (curry snd)

overlayEbuilds ::  Map Category (Map Package [Variant]) ->
                   Map Category (Map Package [Variant]) ->
                   Map Category (Map Package [Variant])
overlayEbuilds   =  M.unionWith (M.unionWith shadowVariants)
  where
    shadowVariants :: [Variant] -> [Variant] -> [Variant]
    shadowVariants vs1 vs2 = vs2 ++ foldr shadowVariant vs1 vs2

    shadowVariant :: Variant -> [Variant] -> [Variant]
    shadowVariant (Variant (EbuildMeta { pv = (PV _ _ v), location = l }) _) vs = 
        [  if v == w then Variant (m { masked = (Shadowed l) : masked m }) x else o | 
           o@(Variant (m@(EbuildMeta { pv = (PV _ _ w) })) x) <- vs ]

-- | Combine a tree with the tree of installed packages. Unlike 'overlayTree', the
--   installed packages do not shadow other packages.
overlayInstalledTree :: Tree -> Tree -> Tree
overlayInstalledTree (Tree ec1 eb1) (Tree ec2 eb2) = 
                                             Tree  (overlayEclasses          ec1  ec2)
                                                   (overlayInstalledEbuilds  eb1  eb2)

overlayInstalledEbuilds ::  Map Category (Map Package [Variant]) ->
                            Map Category (Map Package [Variant]) ->
                            Map Category (Map Package [Variant])
overlayInstalledEbuilds = M.unionWith (M.unionWith (flip (++)))


cacheEntry ::  FilePath -> PV -> FilePath
cacheEntry pt pv = cacheDir pt ./. showPV pv

-- | Returns the list of categories (from disk).
categories :: Config -> IO [Category]
categories c =  unsafeInterleaveIO $
                do  r <- findOverlayFile  c categoriesFile 
                                          (\f -> fmap lines (strictReadFile f)) (++)
                    case r of
                      Nothing  ->  error "categories: file not found, corrupted portage tree?"
                      Just x   ->  return x

-- | Performs a traversal on a tree.
traverseTree :: (Variant -> Variant) -> Tree -> Tree
traverseTree f (Tree c e) =
  Tree c (M.map (M.map (map (\var -> f var))) e)

-- | Modifies a tree at a single location.
modifyTree :: Category -> Package -> (Variant -> Variant) -> Tree -> Tree
modifyTree cat pkg f t = t  {  ebuilds = 
                                 M.update  (\ps -> Just (M.update  (\vs -> Just (map f vs))
                                                                   pkg ps))
                                           cat (ebuilds t)
                            }

-- | Finds and parses a file in a list of overlays.
findOverlayFile  ::  Config                     -- ^ portage configuration
                 ->  (FilePath -> FilePath)     -- ^ the filename (modulo portage tree)
                 ->  (FilePath -> IO a)         -- ^ the parser
                 ->  (a -> a -> a)              -- ^ how to merge
                 ->  IO (Maybe a)
findOverlayFile c f p mrg =
  let  files = map f (trees c)
       testFile n = do  ex <- doesFileExist n
                        if ex  then  fmap (:[]) (p n)
                               else  return []
  in   do  found <- mapM testFile files >>= return . concat
           return $  case found of
                       []  ->  Nothing
                       xs  ->  Just (foldl1 mrg xs)

-- | Safe lookup function for trees.
(!?) :: Tree -> (Category,Package) -> [Variant]
t !? (cat,pkg) =  concat $
                  do  p <- M.lookup cat (ebuilds t)
                      M.lookup pkg p

