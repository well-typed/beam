{-# LANGUAGE RecordWildCards #-}
module Main where

import Database.Beam
import Database.Beam.Migrate.Tool
import Database.Beam.Migrate.Types

import Control.Monad

import Data.Monoid
import Data.Proxy
import Data.Dynamic

import Options.Applicative
import Options.Applicative.Internal
import Options.Applicative.Types

import System.Directory
import System.IO
import System.Exit
import System.Environment

import Language.Haskell.Interpreter
import Language.Haskell.Interpreter.Unsafe

showUsage :: ParserFailure ParserHelp -> ParserInfo a -> IO b
showUsage failure opts =
  do progn <- getProgName
     let (helpMsg, exit) = renderFailure failure progn
     hPutStrLn stderr helpMsg
     exitWith exit

parsePartial :: ParserInfo a -> Args -> Either (ParserFailure ParserHelp) (a, Args)
parsePartial info a =
  let p = runParser (if infoIntersperse info then SkipOpts else AllowOpts) CmdStart (infoParser info) a
  in case runP p defaultPrefs of
    (Left err, ctxt) -> Left (parserFailure defaultPrefs info err ctxt)
    (Right (a, remaining), ctxt) -> Right (a, remaining)

main :: IO ()
main = do
  args <- getArgs

  let bareInfo = migrationCommandOptions (pure ())
  case parsePartial bareInfo args of
    Left err ->
      do hPutStrLn stderr "Could not determine backend"
         putStrLn (show err)
         showUsage err bareInfo
    Right (BeamMigrationCommand {..}, _) ->
      do putStrLn $ "Loading backend '" ++ migrationCommandBackend ++ "'..."
         putStrLn $ "Loading dirs " ++ show migrationCommandPackagePath
         let ghciArgs = foldMap (\p -> [ "-package-db", p]) migrationCommandPackagePath
             runInterpreter' = unsafeRunInterpreterWithArgs ghciArgs
         res <- runInterpreter' $ do
           unsafeSetGhcOption "-v"
           setImports [ "Database.Beam.Migrate.Tool",  migrationCommandBackend ]
           interpret "SomeBeamMigrationBackend migrationBackend" (undefined :: SomeBeamMigrationBackend)
         case res of
           Left err -> hPutStrLn stderr ("Plugin load error: " ++ show err)
           Right (SomeBeamMigrationBackend be@(BeamMigrationBackend {..} :: BeamMigrationBackend cmdSyntax beOptions)) ->
             do (opts, subcommand) <- execParser (migrationCommandAndSubcommandOptions backendOptsParser)
                putStrLn "Loading migration from migrations directory..."
                migration <- runInterpreter' $ do
                  reset
                  set [ languageExtensions := [ TypeFamilies, GADTs, RankNTypes, FlexibleInstances, FlexibleContexts, DeriveGeneric
                                              , ScopedTypeVariables, MultiParamTypeClasses, OverloadedStrings ] ]
                  loadModules [ migrationCommandMigrationModule ]
                  setImports [ "Data.Dynamic"
                             , "Database.Beam.Migrate.Tool"
                             , migrationCommandBackend ]
                  setTopLevelModules [ migrationCommandMigrationModule ]
                  interpret "toDyn (migration >> return ())" (undefined :: Dynamic)
                case migration of
                  Left err -> do hPutStrLn stderr "Plugin error: could not load migrations: "
                                 case err of
                                   WontCompile errs -> mapM_ (hPutStrLn stderr . errMsg) errs
                                   _ -> hPutStrLn stderr (show err)
                  Right migration ->
                    case fromDynamic migration of
                      Nothing -> hPutStrLn stderr "Migration did not have correct type"
                      Just (migration :: MigrationSteps cmdSyntax ()) ->
                        invokeMigrationTool be opts subcommand migration
