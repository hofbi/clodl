{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

module Main where

import Codec.Archive.Zip
  ( addEntryToArchive
  , emptyArchive
  , fromArchive
  , toArchive
  , toEntry
  )
import Control.Monad (unless)
import Data.Text (pack, strip, unpack)
import Data.List (intercalate, isInfixOf)
import qualified Data.ByteString.Lazy as BS
import System.Directory (copyFile, doesFileExist)
import System.Environment (getArgs, getExecutablePath)
import System.FilePath ((</>), (<.>), isAbsolute, takeBaseName, takeFileName)
import System.Info (os)
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (withSystemTempFile)
import System.Process (callProcess, readProcess)
import Text.Regex.TDFA

stripString :: String -> String
stripString = unpack . strip . pack

-- | Add @$ORIGIN@ to RPATH and dependency on @libHSjarify.so@.
patchElf :: FilePath -> IO ()
patchElf exe = do
    rpath <- readProcess "patchelf" ["--print-rpath", exe] ""
    let newrpath = intercalate ":" ["$ORIGIN", rpath]
    callProcess "patchelf" ["--set-rpath", newrpath, exe]

doPackage :: FilePath -> FilePath -> IO ()
doPackage baseJar cmd = do
    jarbytes <- BS.readFile baseJar
    cmdpath <- doesFileExist cmd >>= \case
      False -> stripString <$> readProcess "which" [cmd] ""
      True -> return cmd
    (hsapp, libs) <- withSystemTempFile "hsapp" $ \tmp _ -> do
      copyFile cmdpath tmp
      patchElf tmp
      ldd <- case os of
        "darwin" -> do
          hPutStrLn
            stderr
            "WARNING: JAR not self contained on OS X (shared libraries not copied)."
          return ""
        _ -> readProcess "ldd" [tmp] ""
      self <- getExecutablePath
      selfldd <- readProcess "ldd" [self] ""
      let unresolved =
            map fst $
            filter (not . isAbsolute . snd) $
            map (\xs -> (xs !! 1, xs !! 2)) (ldd =~ "(.+) => (.+)" :: [[String]])
          matchOutput xs =
            map (!! 1) (xs =~ " => (.*) \\(0x[0-9a-f]+\\)" :: [[String]])
          libs =
            filter
              (\x -> not $ any (`isInfixOf` x) ["libc.so", "libpthread.so"])
              (matchOutput ldd) ++
            -- Guarantee that libHSjarify is part of libs set.
            filter
              ("libHSjarify" `isInfixOf`)
              (matchOutput selfldd)
      unless (null unresolved) $
        fail $
          "Unresolved libraries in " ++
          cmdpath ++
          ":\n" ++
          unlines unresolved
      (, libs) <$> BS.readFile tmp
    libentries <- mapM mkEntry libs
    let cmdentry = toEntry "hsapp" 0 hsapp
        appzip =
          toEntry "jarify-app.zip" 0 $
          fromArchive $
          foldr addEntryToArchive emptyArchive (cmdentry : libentries)
        newjarbytes = fromArchive $ addEntryToArchive appzip (toArchive jarbytes)
    BS.writeFile ("." </> takeBaseName cmd <.> "jar") newjarbytes
  where
    mkEntry file = toEntry (takeFileName file) 0 <$> BS.readFile file

main :: IO ()
main = do
    argv <- getArgs
    case argv of
      ["--base-jar", baseJar, path] -> doPackage baseJar path
      _ -> fail "Usage: jarify --base-jar <file> <command>"
