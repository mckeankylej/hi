{-# LANGUAGE NamedFieldPuns  #-}
{-# LANGUAGE RecordWildCards #-}
module Hi
  (
    run
  , process
  ) where

import           Hi.Directory            (inDirectory)
import           Hi.FilePath             (rewritePath)
import qualified Hi.Git                  as Git
import           Hi.Template             (readTemplates)
import           Hi.Types

import           Control.Applicative
import           Control.Monad
import qualified Data.ByteString.Char8   as BS
import qualified Data.ByteString.Lazy    as LBS (toChunks)
import           Data.List               ((\\))
import           Data.Maybe              (fromJust)
import qualified Data.Text               as T (pack, unpack)
import           Data.Text.Encoding      (decodeUtf8)
import           Data.Text.Lazy.Encoding (encodeUtf8)
import           Data.Text.Template      (Context, substitute)
import           System.Directory        (createDirectoryIfMissing)
import           System.FilePath         (dropFileName, joinPath, normalise,
                                          splitPath)
import           System.Process          (system)

-- | Run 'hi'.
run :: Option -> IO ()
run option@(Option {templateSource}) = do
    putStrLn $ "Creating new project with " ++ sourceName templateSource
    writeFiles =<< showFileList =<< process option <$> readTemplates templateSource
    postProcess option
  where
    sourceName (FromRepo repository) = "git repository:" ++ Git.expandUrl repository

-- |Write given 'Files' to filesystem.
writeFiles :: Files -> IO ()
writeFiles = mapM_ write

write :: File -> IO ()
write f = let path = getFilePath f
              contents = getFileContents f
          in createDirectoryIfMissing True (dropFileName path) >>
               BS.writeFile path contents

-- | Show 'Files' to stdout.
showFileList :: Files -> IO Files
showFileList files = do
    mapM_ (showFile . normalise. getFilePath) files
    return files
  where
    showFile :: FilePath -> IO ()
    showFile path = putStrLn $ "    " ++ green "create" ++ "  " ++ path
    green :: String -> String
    green x = "\x1b[32m" ++ x ++ "\x1b[0m"

-- |Process given 'Files' and return result. it does
--
-- 1. rewrite path
--
-- 2. substitute arguments
process :: Option -> Files -> Files
process Option {..} files = map go (dropExtraRegularFiles files)
  where
    go (TemplateFile path content) = TemplateFile (rewritePath' path) (substitute' content)
    go (RegularFile  path content) = RegularFile  (rewritePath' path) content
    rewritePath' path = joinPath $ packageName : splitPath (rewritePath packageName moduleName path)
    substitute' text = BS.concat . LBS.toChunks . encodeUtf8 $
                        substitute (decodeUtf8 text) (context options)
    options          = [("packageName", packageName)
                       ,("moduleName", moduleName)
                       ,("author", author)
                       ,("email", email)
                       ,("year", year)
                       ]

-- | Return 'Context' obtained by given 'Options'
context :: [(String, String)] -> Context
context opts x = T.pack . fromJust $ lookup (T.unpack x) opts

postProcess :: Option -> IO ()
postProcess Option {packageName, afterCommands} = do
    void $ inDirectory packageName $ forM_ afterCommands (void . system)

-- | Drop 'RegularFile's if there is a 'TemplateFile' which has same name
--
-- >>> dropExtraRegularFiles [TemplateFile "foo" (BS.pack "e"), RegularFile "foo" (BS.pack "e")]
-- [TemplateFile {getFilePath = "foo", getFileContents = "e"}]
--
-- >>> dropExtraRegularFiles [RegularFile "foo" (BS.pack "e")]
-- [RegularFile {getFilePath = "foo", getFileContents = "e"}]
--
dropExtraRegularFiles :: Files -> Files
dropExtraRegularFiles []     = []
dropExtraRegularFiles xs = go (map getFilePath xs) xs
  where
    go _ []       = []
    go paths (y@(RegularFile p _):ys)  = if p `elem` (paths \\ [p])
                                           then go paths ys
                                           else y : go paths ys
    go paths (y@(TemplateFile _ _):ys) = y : go paths ys
