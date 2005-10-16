{-| Maintainer  :  Andres Loeh <kosmikus@gentoo.org>
    Stability   :  provisional
    Portability :  haskell98

    Ebuilds and cache entries.
-}

module Portage.Ebuild
  where

import Portage.Dependency
import Portage.Use
import Portage.Keyword

-- The ebuild cache format (as created by calling "ebuild depend") is as follows:
-- DEPEND
-- RDEPEND
-- SLOT
-- SRC_URI
-- RESTRICT
-- HOMEPAGE
-- LICENSE
-- DESCRIPTION
-- KEYWORDS
-- INHERITED
-- IUSE
-- CDEPEND
-- PDEPEND
-- PROVIDE

data Ebuild = Ebuild  {  depend       ::  DepString,
                         rdepend      ::  DepString,
                         slot         ::  String,
                         src_uri      ::  String,
                         restrict     ::  [String],
                         homepage     ::  String,
                         license      ::  String,
                         description  ::  String,
                         keywords     ::  [Keyword],
                         inherited    ::  String,
                         iuse         ::  [UseFlag],
                         cdepend      ::  DepString,
                         pdepend      ::  DepString,
                         provide      ::  DepAtom 
                      }
  deriving (Show,Eq)


getEbuild :: String -> Ebuild
getEbuild e  |  length l <= 14  =  error "getEbuild: corrupted ebuild (too short)"
             |  otherwise       =  Ebuild  (getDepString dep)
                                           (getDepString rdep)
                                           slt
                                           src
                                           (words restr)
                                           home
                                           lic
                                           des
                                           (splitKeywords key)
                                           inh
                                           (splitUse use)
                                           (getDepString cdep)
                                           (getDepString pdep)
                                           (getDepAtom prov)
  where l = lines e
        (dep:rdep:slt:src:restr:home:lic:des:key:inh:use:cdep:pdep:prov:_) = l
