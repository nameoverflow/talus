-- Example of a program that emits xmobar-like markup. Configure its absolute
-- runghc path as the executable, this file as an argument, and markup: true.
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
main :: IO ()
main = do
  now <- getZonedTime
  putStrLn $ "<fc=#89CFC2>λ " ++ formatTime defaultTimeLocale "%H:%M" now ++ "</fc>"
