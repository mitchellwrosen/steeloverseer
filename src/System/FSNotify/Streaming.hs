-- | A streaming wrapper around System.FSNotify.

module System.FSNotify.Streaming
  ( System.FSNotify.Streaming.watchTree
    -- * Re-exports
  , Event(..)
  , WatchManager
  , WatchConfig(..)
  , Debounce(..)
  , defaultConfig
  ) where

import Control.Concurrent.Chan
import Control.Exception (bracket)
import Control.Monad
import Control.Monad.Managed
import Streaming (Of, Stream)
import Streaming.Prelude (yield)
import System.FSNotify

watchTree
  :: WatchConfig
  -> FilePath
  -> (Event -> Bool)
  -> (Stream (Of Event) IO () -> IO r)
  -> IO r
watchTree config path predicate run = do
  chan :: Chan Event <-
    newChan

  withManagerConf config $ \manager ->
    withTreeChan manager path predicate chan $
      run (forever (liftIO (readChan chan) >>= yield))

withTreeChan
  :: WatchManager -> FilePath -> ActionPredicate -> EventChannel -> IO a -> IO a
withTreeChan manager path predicate chan act =
  bracket
    (watchTreeChan manager path predicate chan)
    id
    (\_ -> act)
