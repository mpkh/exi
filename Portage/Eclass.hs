{-|
    Maintainer  :  Andres Loeh <kosmikus@gentoo.org>
    Stability   :  provisional
    Portability :  haskell98

    Eclasses.
-}

module Portage.Eclass
  where

import System.IO
import System.Posix

import Portage.Shell
import Portage.Utilities

type Eclass  =  String

-- | The 'EclassMeta' type contains information about the identity of
--   an eclass. We use modification time and tree location.
data EclassMeta =  EclassMeta
                     {
                        location  ::  FilePath, -- only the portage tree path including eclass; use 'TreeLocation' instead?
                        mtime     ::  MTime
                     }
  deriving (Show,Eq)

-- We do not save shadowed eclasses, because unlike ebuilds, eclasses
-- are not directly visible to the user (although this might change in
-- the future). Having only one eclass per name in the finite map
-- simplifies the situation a bit.

-- | Splits a string of eclasses.
splitEclasses :: String -> [Eclass]
splitEclasses = words

-- | Reads a file associating eclasses with mtimes.
readEclassesFile :: FilePath -> IO [(Eclass,FilePath,MTime)]
readEclassesFile f =  do
                          c <- strictReadFile f
                          return $
                            map  ((\[x,y,z] -> (x,y,read z)) . split '\t')
                                 (filter (not . null) (lines c))

-- | Writes a file associating eclasses with mtimes.
writeEclassesFile :: FilePath -> [(Eclass,FilePath,MTime)] -> IO ()
writeEclassesFile f c =  do
                             let out  =  map  (\(e,l,m) -> e ++ "\t" ++ l ++ "\t" ++ show m) c
                             h <- openFile f WriteMode
                             hPutStr h (unlines out)
                             hClose h
