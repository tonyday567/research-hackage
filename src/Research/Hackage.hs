{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE BlockArguments #-}
{-# HLINT ignore "Redundant bracket" #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Research.Hackage
  ( -- * archive extraction
    archive,

    -- * content
    groupByHeader,
    groupByPathName,
    packageStream,
    NameType (..),
    toNameType,
    names,
    authors,
    fieldValue,
    fieldValues,
    sec,
    secName,
    rawBuildDeps,

    -- * streamly folds
    count,
    collect,
    collect',

    -- * flatparse parsers
    paths,
    parsePath,
    parseVersion,
    toVer,
    parseDeps,

    -- * collections
    validLatestCabals,
    validLatestExeOnlys,
    validLatestLibs,

    -- * graphics
    upstreams,
    diffUpstreamSet,
  )
where

import Algebra.Graph hiding (empty)
import qualified Algebra.Graph.ToGraph as ToGraph
import Control.Applicative (liftA2)
import Crypto.Hash (hashFinalize, hashInit, hashUpdate)
import Crypto.Hash.Algorithms (SHA256)
import Data.Bifunctor
import Data.Bool
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Char (ord)
import Data.Either
import Data.Foldable
import Data.Function ((&))
import Data.Functor.Identity
import qualified Data.Graph.Inductive.Graph as G
import Data.Graph.Inductive.PatriciaTree (Gr)
import Data.Graph.Inductive.Query.DFS
import qualified Data.IntMap.Strict as IntMap
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Void (Void)
import Distribution.Fields
import Distribution.Fields.Field
import Distribution.Parsec.Position (Position)
import FlatParse.Basic
import GHC.IO.Unsafe (unsafePerformIO)
import Streamly.External.Archive
import Streamly.Internal.Data.Fold.Type (Fold (Fold), Step (Partial))
import qualified Streamly.Internal.Data.Unfold as Unfold
import Streamly.Internal.Data.Unfold.Type (Unfold)
import qualified Streamly.Prelude as S
import System.Directory

-- $setup
--
-- >>> :set -XOverloadedStrings
-- >>> import Research.Hackage
-- >>> import qualified Streamly.Prelude as S
-- >>> import qualified Streamly.Internal.Data.Unfold as Unfold
-- >>> import Data.Function
-- >>> import Streamly.External.Archive
-- >>> import Data.Either
-- >>> import qualified Data.ByteString.Char8 as C
-- >>> import Data.Bifunctor
-- >>> import qualified Data.Map.Strict as Map
-- >>> import FlatParse.Basic

-- | The local archive
archive :: Unfold IO Void (Either Header ByteString)
archive =
  readArchive $
    unsafePerformIO getHomeDirectory
      <> "/.cabal/packages/hackage.haskell.org/01-index.tar"

data HeaderInfo = HeaderInfo
  { fileType :: Maybe FileType,
    pathName :: Maybe ByteString,
    pathNameUtf8 :: Maybe ByteString,
    size :: Maybe Int
  }
  deriving (Eq, Show)

getHeaderInfo :: Header -> IO HeaderInfo
getHeaderInfo h = do
  ft <- headerFileType h
  pn <- headerPathName h
  pnu <- headerPathNameUtf8 h
  s <- headerSize h
  pure (HeaderInfo ft pn pnu s)

rollHeader :: Fold IO (Either Header ByteString) (Maybe HeaderInfo, Maybe ByteString)
rollHeader = Fold step initial done
  where
    step ::
      (Maybe HeaderInfo, Maybe ByteString) ->
      Either Header ByteString ->
      IO (Step (Maybe HeaderInfo, Maybe ByteString) (Maybe HeaderInfo, Maybe ByteString))
    step (minfo, mctx) e =
      case e of
        Left h -> do
          minfo' <- getHeaderInfo h
          pure $ Partial (Just minfo', mctx)
        Right bs -> pure $ Partial (minfo, mctx <> Just bs)

    initial :: IO (Step (Maybe HeaderInfo, Maybe ByteString) (Maybe HeaderInfo, Maybe ByteString))
    initial = pure (Partial (Nothing, Nothing))

    done :: (Maybe HeaderInfo, Maybe ByteString) -> IO (Maybe HeaderInfo, Maybe ByteString)
    done = pure

-- Execute the stream, grouping at the headers (the Lefts).
groupByHeader ::
  S.IsStream t =>
  Unfold IO a (Either Header ByteString) ->
  t IO (Maybe HeaderInfo, Maybe ByteString)
groupByHeader arc =
  S.unfold arc undefined
    & S.groupsBy (\e _ -> isRight e) rollHeader

rollName :: Fold IO (Either Header ByteString) (ByteString, ByteString)
rollName = Fold step initial done
  where
    step ::
      (Maybe ByteString, Maybe ByteString) ->
      Either Header ByteString ->
      IO (Step (Maybe ByteString, Maybe ByteString) (ByteString, ByteString))
    step (name, bs) e =
      case e of
        Left h -> do
          name' <- headerPathName h
          pure $ Partial (name', bs)
        Right bs' -> pure $ Partial (name, bs <> Just bs')

    initial :: IO (Step (Maybe ByteString, Maybe ByteString) (ByteString, ByteString))
    initial = pure (Partial (Nothing, Nothing))

    done :: (Maybe ByteString, Maybe ByteString) -> IO (ByteString, ByteString)
    done = pure . bimap (fromMaybe mempty) (fromMaybe mempty)

-- | Execute the stream, grouping by pathName.
groupByPathName ::
  S.IsStream t =>
  Unfold IO a (Either Header ByteString) ->
  t IO (ByteString, ByteString)
groupByPathName arc =
  S.unfold arc undefined
    & S.groupsBy (\e _ -> isRight e) rollName

-- | package stream: tuple is (name, cabal file)
packageStream :: S.IsStream t => t IO (ByteString, ByteString)
packageStream = groupByPathName (Unfold.take 10000000 archive)

-- | The types of files in the archive.
data NameType = CabalName | PreferredVersions | PackageJson | BadlyNamed deriving (Show, Ord, Eq)

toNameType :: ByteString -> NameType
toNameType bs
  | B.isSuffixOf "preferred-versions" bs = PreferredVersions
  | B.isSuffixOf "package.json" bs = PackageJson
  | B.isSuffixOf ".cabal" bs = CabalName
  | otherwise = BadlyNamed

-- | Unification of field and section names
names :: Field a -> ByteString
names (Field (Name _ n) _) = n
names (Section (Name _ n) _ _) = n

author :: Field a -> [ByteString]
author (Field (Name _ "author") xs) = fieldLineBS <$> xs
author _ = []

-- | author information
authors :: [Field a] -> [ByteString]
authors xs = mconcat $ fmap author xs

-- | extract a field's values, if any
fieldValue :: ByteString -> Field a -> [ByteString]
fieldValue f (Field (Name _ n) xs) = bool [] (fieldLineBS <$> xs) (f == n)
fieldValue _ _ = []

-- | extract a field values from a list, if any
fieldValues :: ByteString -> [Field a] -> [ByteString]
fieldValues v xs = mconcat $ fmap (fieldValue v) xs

-- | section deconstruction
sec :: FieldName -> Field ann -> Maybe ([SectionArg ann], [Field ann])
sec f (Section (Name _ n) sargs fs) = bool Nothing (Just (sargs, fs)) (f == n)
sec _ (Field _ _) = Nothing

-- | SectionArg name
secName :: SectionArg a -> (ByteString, ByteString)
secName (SecArgName _ n) = ("name", n)
secName (SecArgStr _ n) = ("str", n)
secName (SecArgOther _ n) = ("other", n)

-- | extract build-deps from a Field list, also looking in common stanzas
rawBuildDeps :: [Field a] -> [[ByteString]]
rawBuildDeps xs =
  bdeps <> bdepImports
  where
    libs = fmap snd . mapMaybe (sec "library") $ xs
    bdeps = fmap (fieldValues "build-depends") libs
    libImports = fmap (fieldValues "import") libs
    common = mapMaybe (sec "common") xs
    cbdMap =
      Map.fromList $
        fmap
          (bimap (fromJust . listToMaybe . fmap (snd . secName)) (fieldValues "build-depends"))
          common
    bdepImports =
      fmap
        ( mconcat
            . fmap (\x -> fromMaybe [] $ Map.lookup x cbdMap)
        )
        libImports

-- * streamly 'Fold's

-- | a counter, folding into a map.
count :: (Applicative m, Ord a) => Fold m a (Map.Map a Int)
count = Fold step initial done
  where
    step x a = pure $ Partial $ Map.insertWith (+) a 1 x
    initial = pure $ Partial Map.empty
    done = pure

-- | split an 'a' into a key-value pair where the value is a monoid, and collect into a map.
collect :: (Applicative m, Ord k) => (a -> k) -> (a -> v) -> Fold m a (Map.Map k [v])
collect k v = Fold step initial done
  where
    step x a = pure $ Partial $ Map.insertWith (<>) (k a) [v a] x
    initial = pure $ Partial Map.empty
    done = pure

-- | split an 'a' into a key-value pair, and collect into a map, combining with the supplied function.
collect' :: (Applicative m, Ord k) => (a -> k) -> (a -> v) -> (v -> v -> v) -> Fold m a (Map.Map k v)
collect' k v c = Fold step initial done
  where
    step x a = pure $ Partial $ Map.insertWith c (k a) (v a) x
    initial = pure $ Partial Map.empty
    done = pure

-- * flatparse parsing

slash :: Parser () ()
slash = $(char '/')

notslash :: Parser () String
notslash = chainr (:) (satisfy (/= '/')) (fmap (const []) slash)

cabalSuffix :: Parser () ()
cabalSuffix = $(string ".cabal")

notcabal :: Parser () String
notcabal = chainr (:) anyChar (fmap (const []) cabalSuffix)

-- | parse a .cabal path into a list of sections
--
-- >>> runParser paths "1/2/3.cabal"
-- OK ["1","2","3.cabal"] ""
paths :: Parser () [String]
paths = (\xs e -> xs <> [e]) <$> many notslash <*> takeRest

-- | run the paths Parser, lefting on a badly formed path
--
-- >>> S.toList $ S.take 100 $ S.filter isLeft $ fmap (parsePath . fst) $ S.filter ((==CabalName) . toNameType . fst) (packages (Unfold.take 10000000 archive))
-- []
parsePath :: ByteString -> Either ByteString (String, String)
parsePath bs = case runParser paths bs of
  OK [a, b, c] "" -> bool (Left bs) (Right (a, b)) (Just (C.pack a) == B.stripSuffix ".cabal" (C.pack c))
  _ -> Left bs

-- | version number parsing
--
-- >>> parseVersion "1.0.0.1"
-- Right [1,0,0,1]
parseVersion :: ByteString -> Either ByteString [Int]
parseVersion bs = case runParser ints' bs of
  OK [] _ -> Left bs
  OK xs "" -> Right xs
  _ -> Left bs

-- | convert from a version list to a bytestring.
toVer :: [Int] -> ByteString
toVer xs = B.intercalate "." (C.pack . show <$> xs)

digit :: Parser () Int
digit = (\c -> ord c - ord '0') <$> satisfyASCII isDigit

int :: Parser () Int
int = do
  (place, n) <- chainr (\n (!place, !acc) -> (place * 10, acc + place * n)) digit (pure (1, 0))
  case place of
    1 -> empty
    _ -> pure n

ints' :: Parser () [Int]
ints' = (\xs e -> xs <> [e]) <$> many (const <$> int <*> vdot) <*> int

vdot :: Parser () ()
vdot = $(char '.')

comma :: Parser () ()
comma = $(string ",")

-- | braces
braces :: Parser () String
braces =
  $(string "{")
    *> many (satisfyASCII (/= '}'))
    <* $(string "}")

parseOK :: Parser e a -> ByteString -> Either ByteString a
parseOK p bs = case runParser p bs of
  OK a "" -> Right a
  _ -> Left bs

initialPackageChar :: Parser () Char
initialPackageChar =
  satisfyASCII
    ( `C.elem`
        ( C.pack $
            ['a' .. 'z']
              <> ['A' .. 'Z']
              <> ['0' .. '9']
        )
    )

packageChar :: Parser () Char
packageChar =
  satisfyASCII
    ( `C.elem`
        ( C.pack $
            ['a' .. 'z']
              <> ['A' .. 'Z']
              <> ['-']
              <> ['0' .. '9']
        )
    )

invalidPackageChar :: Parser () Char
invalidPackageChar =
  satisfyASCII
    ( `C.notElem`
        ( C.pack $
            ['a' .. 'z']
              <> ['A' .. 'Z']
              <> ['-']
              <> ['0' .. '9']
        )
    )

validName :: Parser () String
validName = (:) <$> initialPackageChar <*> many packageChar

depField :: Parser () ByteString
depField = C.pack . mconcat <$> many (some (satisfyASCII (not . (`elem` [',', '{']))) <|> braces)

adep :: Parser () String
adep = many invalidPackageChar *> validName <* takeLine

intercalated :: Parser () item -> Parser () sep -> Parser () [item]
intercalated item sep =
  optional comma
    *> ((:) <$> item <*> chainr (:) (sep *> item) (pure []))
    <* optional comma

-- | dependency name
--
-- >>> parseDeps "base ^>= { 4.12, 4.13, 4.14 } && == { 4.15, 4.16 } || == 5 , containers ^>= 0.6.2.1,deepseq ^>= 1.4"
-- Right ["base","containers","deepseq"]
parseDeps :: ByteString -> Either ByteString [String]
parseDeps bs = case bs of
  "" -> Right []
  bs' ->
    bool
      (fmap (fmap (fromRight undefined) . filter isRight) ds)
      (Left bs')
      (either (const True) (any isLeft) ds)
    where
      xs = parseOK (intercalated depField comma) bs'
      ds = second (fmap (parseOK adep) . filter (/= "")) xs

-- | A map of the latest version number and cabal file for all packages.
latestCabalFiles :: IO (Map.Map String ([Int], ByteString))
latestCabalFiles =
  S.fold
    ( collect'
        (fst . fst)
        (\((_, v), c) -> (v, c))
        (\x y -> bool x y (fst x < fst y))
    )
    $ fmap (first (second (fromRight undefined))) $
      S.filter (isRight . snd . fst) $
        fmap
          (first (second (parseVersion . C.pack) . fromRight undefined))
          ( S.filter (isRight . fst) $
              first parsePath
                <$> S.filter
                  ((== CabalName) . toNameType . fst)
                  packageStream
          )

-- | valid cabal files with all fields parsing ok
validLatestCabals :: IO (Map.Map String ([Int], [Field Position]))
validLatestCabals =
  fmap (second (fromRight undefined)) . Map.filter (isRight . snd) . fmap (second readFields) <$> latestCabalFiles

-- | valid cabal files with all fields parsing ok, and at least one library section.
validLatestLibs :: IO (Map.Map String ([Int], [Field Position]))
validLatestLibs = do
  Map.filter (not . null . mapMaybe (sec "library") . snd) <$> validLatestCabals

-- | valid cabal files with all fields parsing ok, but no library section.
validLatestExeOnlys :: IO (Map.Map String ([Int], [Field Position]))
validLatestExeOnlys = do
  Map.filter (null . mapMaybe (sec "library") . snd) <$> validLatestCabals

diffUpstreamSet :: (ToGraph.ToGraph t, Ord (ToGraph.ToVertex t)) => t -> Set (ToGraph.ToVertex t) -> Set (ToGraph.ToVertex t)
diffUpstreamSet g x = Set.difference (mconcat (fmap (`ToGraph.postSet` g) . toList $ x)) x

upstreams :: (ToGraph.ToGraph t, Ord (ToGraph.ToVertex t)) => ToGraph.ToVertex t -> t -> Set (ToGraph.ToVertex t)
upstreams t g = go (t `ToGraph.postSet` g)
  where
    go s =
      let s' = diffUpstreamSet g s
       in bool (go (s <> s')) s (Set.empty == s')
