module Cli where

import Sos.Rule (RawPattern)
import Sos.Template (RawTemplate)

import Control.Monad (join)
import Options.Applicative

cliMain
  :: (FilePath -> FilePath -> [RawTemplate] -> [RawPattern] -> [RawPattern]
      -> IO ())
  -> IO ()
cliMain main = join (execParser sosParserInfo)
 where
  sosParserInfo :: ParserInfo (IO ())
  sosParserInfo = info (helper <*> sosParser) sosInfoMod

  sosParser :: Parser (IO ())
  sosParser = main
    <$> sosTargetParser
    <*> sosRcfileParser
    <*> many sosCommandParser
    <*> many sosPatternParser
    <*> many sosExcludeParser

sosInfoMod :: InfoMod (IO ())
sosInfoMod = mconcat
  [ fullDesc
  , progDesc "A file watcher and development tool."
  , header "Steel Overseer 2.0.2"
  ]

sosTargetParser :: Parser FilePath
sosTargetParser = strArgument mods
 where
  mods :: Mod ArgumentFields FilePath
  mods = mconcat
    [ help "Optional file or directory to watch for changes."
    , metavar "TARGET"
    , value "."
    , showDefault
    ]

sosRcfileParser :: Parser FilePath
sosRcfileParser = strOption mods
 where
  mods :: Mod OptionFields FilePath
  mods = mconcat
    [ help "Optional rcfile to read patterns and commands from."
    , long "rcfile"
    , value ".sosrc"
    , showDefault
    ]

sosCommandParser :: Parser RawTemplate
sosCommandParser = strOption mods
 where
  mods :: Mod OptionFields RawTemplate
  mods = mconcat
    [ long "command"
    , short 'c'
    , help "Add command to run on file event."
    , metavar "COMMAND"
    ]

sosPatternParser :: Parser RawPattern
sosPatternParser = strOption mods
 where
  mods :: Mod OptionFields RawPattern
  mods = mconcat
    [ long "pattern"
    , short 'p'
    , help "Add pattern to match on file path. Only relevant if the target is a directory. (default: .*)"
    , metavar "PATTERN"
    ]

sosExcludeParser :: Parser RawPattern
sosExcludeParser = strOption mods
 where
  mods :: Mod OptionFields RawPattern
  mods = mconcat
    [ long "exclude"
    , short 'e'
    , help "Add pattern to exclude matches on file path. Only relevant if the target is a directory."
    , metavar "PATTERN"
    ]
