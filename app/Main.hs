{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main where

import Cli (cliMain)
import Sos.FileEvent
  (FileEvent(FileAdded, FileModified), fileEventPath, showFileEvent)
import Sos.Job (Job(Job, jobEvent), ShellCommand, runJob)
import Sos.Rule
  (RawPattern, RawRule, Rule(ruleExclude, rulePattern, ruleTemplates),
    buildRawRule, buildRule)
import Sos.Template (RawTemplate, instantiateTemplate)
import Sos.Utils (cyan, packBS, red)

import Control.Concurrent.Async (Async, async, cancel, race_, waitCatchSTM)
import Control.Monad.Catch (MonadThrow, throwM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.STM (STM, atomically, retry)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Maybe (MaybeT(runMaybeT))
import Control.Concurrent.STM.TMVar
  (TMVar, isEmptyTMVar, newEmptyTMVarIO, putTMVar, swapTMVar, takeTMVar,
    tryReadTMVar)
import Control.Concurrent.STM.TQueue.Extra
import Control.Exception
  (AsyncException(ThreadKilled), Exception(fromException), SomeException)
import Control.Monad (forever, join)
import Control.Monad.Managed.Safe (Managed, managed, runManaged)
import Data.ByteString (ByteString)
import Data.Foldable (asum)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Yaml (decodeFileEither, prettyPrintParseException)
import Streaming (Of, Stream)
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory)
import System.Exit (ExitCode(ExitFailure, ExitSuccess), exitFailure)
import System.FilePath (makeRelative, takeDirectory)
import Text.Printf (printf)
import Text.Regex.TDFA (match)

import qualified Streaming.Prelude as S
import qualified System.FSNotify.Streaming as FSNotify

main :: IO ()
main = cliMain main1

main1
  :: FilePath      -- Target
  -> FilePath      -- RC file
  -> [RawTemplate] -- Commands
  -> [RawPattern]  -- Patterns
  -> [RawPattern]  -- Exclude patterns
  -> IO ()
main1 target rc_file commands patterns excludes = do
  -- Parse .sosrc rules.
  rc_rules :: [Rule] <-
    parseSosrc rc_file

  -- Parse cli rules, where one rule is created per pattern that executes
  -- each of @commands@ sequentially.
  cli_rules :: [Rule] <- do
    let patterns', excludes' :: [RawPattern]
        (patterns', excludes') =
          case (rc_rules, patterns) of
            -- If there are no commands in .sosrc, and no patterns
            -- specified on the command line, default to ".*"
            ([], []) -> ([".*"], [])
            _ -> (patterns, excludes)

    mapM (\pattrn -> buildRule pattrn excludes' commands) patterns'

  (target', rules) <- do
    is_dir <- doesDirectoryExist target
    if is_dir
      then pure (target, cli_rules ++ rc_rules)
      else do
        is_file <- doesFileExist target
        if is_file
          -- If the target is a single file, completely ignore the .sosrc
          -- commands.
          then do
            rule <- buildRule (packBS target) [] commands
            pure (takeDirectory target, [rule])
          else do
            putStrLn ("Target " ++ target ++ " is not a file or directory.")
            exitFailure

  main2 target' rules

main2
  :: FilePath -- Target
  -> [Rule]   -- Rules
  -> IO ()
main2 target rules = do
  putStrLn "Hit Ctrl+C to quit."

  all_job_events :: TQueue Job
    <- newTQueueIO

  let enqueue_thread :: Managed ()
      enqueue_thread =
          watchTree target
        & S.mapM (eventJob rules)
        & S.concat
        & S.mapM_ (liftIO . atomically . writeTQueue all_job_events)

  let -- Dequeue and run 'Job's forever. If a job fails, empty out the queue
      -- of jobs to run, so the output of the failed job is not lost.
      dequeue_thread :: IO a
      dequeue_thread = do
        -- Keep track of the subset of all job events to actually run. We don't
        -- want to enqueue already-enqueued jobs, for example - once is enough.
        jobs_to_run :: TQueue Job
          <- newTQueueIO

        -- The currently-running job, paired with its 'Async' to cancel, await,
        -- or what have you.
        running_job :: TMVar (Job, Async ()) <-
          newEmptyTMVarIO

        let runJobAsync :: Job -> IO ()
            runJobAsync job = do
              putStrLn ("\n" ++ cyan (showFileEvent (jobEvent job)))
              a <- async (runJob job)
              atomically (putTMVar running_job (job, a))

        forever $ do
          let -- A job event occurred. If it's equal to the running job, cancel
              -- it (it will be restarted when we process its ThreadKilled
              -- result). Otherwise, enqueue it if it doesn't already exist.
              action1 :: STM (IO ())
              action1 = do
                job <- readTQueue all_job_events
                pure $
                  atomically (tryReadTMVar running_job) >>= \case
                    Just (job', a) | job == job' -> do
                      -- Slightly hacky here: replace the existing job with the
                      -- new one, because although they contain the same
                      -- commands, when we restart the job, we want to print
                      -- the newer 'FileEvent', which may be different.
                      _ <- atomically (swapTMVar running_job (job, a))
                      cancel a
                    _ ->
                      atomically $
                        elemTQueue jobs_to_run job >>= \case
                          True -> pure ()
                          False -> writeTQueue jobs_to_run job

          let action2 :: STM (IO ())
              action2 = do
                (job, a) <- takeTMVar running_job
                result <- waitCatchSTM a
                pure $
                  case result of
                    Left ex ->
                      case fromException ex of
                        -- The currently-running job died via ThreadKilled. We
                        -- will assume we 'canceled' it to restart it.
                        Just ThreadKilled -> runJobAsync job

                        -- The currently-running job died via some other means.
                        -- We don't want the output to get lost, so we'll just
                        -- empty the job queue for simplicity.
                        _ -> do
                          putStrLn (prettyPrintException ex)
                          atomically (drainTQueue jobs_to_run)

                    -- Job ended successfully!
                    Right () -> pure ()

          let action3 :: STM (IO ())
              action3 =
                isEmptyTMVar running_job >>= \case
                  True -> runJobAsync <$> readTQueue jobs_to_run
                  False -> retry

          join (atomically (asum [action1, action2, action3]))

  race_ (runManaged enqueue_thread) dequeue_thread

eventJob :: MonadIO m => [Rule] -> FileEvent -> m (Maybe Job)
eventJob rules event = runMaybeT $ do
  c:cs <- lift (liftIO (eventCommands rules event))
  pure (Job event (c:|cs))

eventCommands :: [Rule] -> FileEvent -> IO [ShellCommand]
eventCommands rules event = concat <$> mapM go rules
 where
  go :: Rule -> IO [ShellCommand]
  go rule =
    case (patternMatch, excludeMatch) of
      -- Pattern doesn't match
      ([], _) -> pure []
      -- Pattern matches, but so does exclude pattern
      (_, True) -> pure []
      -- Pattern matches, and exclude pattern doesn't!
      (xs, False) -> mapM (instantiateTemplate xs) (ruleTemplates rule)

   where
    patternMatch :: [ByteString]
    patternMatch =
      case match (rulePattern rule) (fileEventPath event) of
        [] -> []
        xs:_ -> xs

    excludeMatch :: Bool
    excludeMatch =
      case ruleExclude rule of
        Nothing -> False
        Just exclude -> match exclude (fileEventPath event)

watchTree :: FilePath -> Stream (Of FileEvent) Managed a
watchTree target = do
  cwd <- liftIO getCurrentDirectory

  let config :: FSNotify.WatchConfig
      config = FSNotify.defaultConfig
        { FSNotify.confDebounce = FSNotify.Debounce 0.1 }

      stream :: Stream (Of FSNotify.Event) Managed a
      stream = FSNotify.watchTree config target (const True)

  S.for stream (\case
    FSNotify.Added    path _ -> S.yield (FileAdded    (go cwd path))
    FSNotify.Modified path _ -> S.yield (FileModified (go cwd path))
    FSNotify.Removed  _    _ -> pure ())
 where
  go :: FilePath -> FilePath -> ByteString
  go cwd path = packBS (makeRelative cwd path)

prettyPrintException :: SomeException -> String
prettyPrintException ex =
  case fromException ex of
    Just ExitSuccess -> red (printf "Failure ✗ (0)")
    Just (ExitFailure code) -> red (printf "Failure ✗ (%d)" code)
    Nothing -> red (show ex)

--------------------------------------------------------------------------------

-- Parse a list of rules from an rcfile.
parseSosrc :: FilePath -> IO [Rule]
parseSosrc sosrc = do
  exists <- doesFileExist sosrc
  if exists
    then
      decodeFileEither sosrc >>= \case
        Left err -> do
          putStrLn ("Error parsing " ++ show sosrc ++ ":\n" ++
            prettyPrintParseException err)
          exitFailure
        Right (raw_rules :: [RawRule]) -> do
          rules <- mapM buildRawRule raw_rules
          putStrLn (case length raw_rules of
                      1 -> "Found 1 rule in " ++ show sosrc
                      n -> "Found " ++ show n ++ " rules in " ++ show sosrc)
          pure (concat rules)
    else pure []

infixl 1 &
(&) :: a -> (a -> b) -> b
(&) x f = f x

--------------------------------------------------------------------------------
-- Orphan instances

instance MonadThrow Managed where
  throwM :: Exception e => e -> Managed a
  throwM e = managed (\_ -> throwM e)
