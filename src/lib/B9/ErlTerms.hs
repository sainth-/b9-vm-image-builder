module B9.ErlTerms (parseErlTerm
                   ,renderErlTerm
                   ,SimpleErlangTerm(..)) where

import Data.Data
import Data.Function
import qualified Data.ByteString.Char8 as B
import Text.Parsec.ByteString
import Text.Parsec
import Test.QuickCheck
import Control.Applicative ((<$>), pure, (<*>))
import Text.Show.Pretty
import Control.Monad
import Text.Printf

data SimpleErlangTerm = ErlString String
                      | ErlFloat Double
                      | ErlNatural Integer
                      | ErlAtom String
                      | ErlChar Char
                      | ErlBinary String
                      | ErlTuple [SimpleErlangTerm]
                      | ErlList [SimpleErlangTerm]
                      deriving (Eq,Ord,Read,Show,Data,Typeable)

parseErlTerm :: String -> B.ByteString -> Either String SimpleErlangTerm
parseErlTerm src content =
  either (Left . ppShow) Right (parse erlTermParser src content)

renderErlTerm :: SimpleErlangTerm -> B.ByteString
renderErlTerm (ErlString str) = B.pack $ "\"" ++ toErlStringString str ++ "\""
renderErlTerm (ErlNatural n) = B.pack (printf "%i" n)
renderErlTerm (ErlFloat f) = B.pack (show f)
renderErlTerm (ErlChar c) = B.pack ("$" ++ toErlAtomChar c)
renderErlTerm (ErlAtom a) = B.pack quotedStr
  where
    quotedStr = if all (`elem` (['a'..'z']++['A'..'Z']++['0'..'9']++"@_")) a'
                then a'
                else "'"++a'++"'"

    a' = toErlAtomString a
renderErlTerm (ErlBinary []) = B.pack "<<>>"
renderErlTerm (ErlBinary b) = B.pack ("<<\"" ++ toErlStringString b ++ "\">>")
renderErlTerm _ =
  error "TODO"

toErlStringString :: String -> String
toErlStringString = join . map toErlStringChar

toErlStringChar :: Char -> String
toErlStringChar = (table !!) . fromEnum
  where
    table = [printf "\\x{%x}" c | c <- [0..(31::Int)]] ++
            (pure <$> toEnum <$> [32 .. 33]) ++
            ["\\\""] ++
            (pure <$> toEnum <$> [35 .. 91]) ++
            ["\\\\"] ++(pure <$> toEnum <$> [93 .. 126]) ++
            [printf "\\x{%x}" c | c <- [(127::Int)..]]

toErlAtomString :: String -> String
toErlAtomString = join . map toErlAtomChar

toErlAtomChar :: Char -> String
toErlAtomChar = (table !!) . fromEnum
  where
    table = [printf "\\x{%x}" c | c <- [0..(31::Int)]] ++
            (pure <$> toEnum <$> [32 .. 38]) ++
            ["\\'"] ++
            (pure <$> toEnum <$> [40 .. 91]) ++
            ["\\\\"] ++(pure <$> toEnum <$> [93 .. 126]) ++
            [printf "\\x{%x}" c | c <- [(127::Int)..]]


instance Arbitrary SimpleErlangTerm where
  arbitrary = oneof [sized aErlString
                    ,sized aErlNatural
                    ,sized aErlFloat
                    ,sized aErlChar
                    ,sized aErlAtomUnquoted
                    ,sized aErlAtomQuoted
                    ,sized aErlBinary
                    ]
    where
      aErlString n =
        ErlString <$> resize (n-1) (listOf (choose (toEnum 0,toEnum 255)))
      aErlFloat n = do
        f <- resize (n-1) arbitrary :: Gen Float
        let d = fromRational (toRational f)
        return (ErlFloat d)
      aErlNatural n =
        ErlNatural <$> resize (n-1) arbitrary
      aErlChar n =
        ErlChar <$> resize (n-1) (choose (toEnum 0, toEnum 255))
      aErlAtomUnquoted n = do
        f <- choose ('a','z')
        rest <- resize (n-1) aErlNameString
        return (ErlAtom (f:rest))
      aErlAtomQuoted n = do
        cs <- resize (n-1) aParsableErlString
        return (ErlAtom ("'" ++ cs ++ "'"))
      aErlBinary n =
        ErlBinary <$> resize (n-1) (listOf (choose (toEnum 0,toEnum 255)))
      aParsableErlString = oneof [aErlNameString
                                 ,aErlEscapedCharString
                                 ,aErlControlCharString
                                 ,aErlOctalCharString
                                 ,aErlHexCharString]
      aErlNameString = listOf (elements (['a'..'z'] ++ ['A'..'Z']++ ['0'..'9']++"@_"))
      aErlEscapedCharString = elements (("\\"++) . pure <$> "0bdefnrstv\\\"\'")
      aErlControlCharString = elements (("\\^"++) . pure <$> (['a'..'z'] ++ ['A'..'Z']))
      aErlOctalCharString = do
        n <- choose (1,3)
        os <- vectorOf n (choose (0,7))
        return (join ("\\":(show <$> (os::[Int]))))
      aErlHexCharString =
        oneof [twoDigitHex,nDigitHex]
        where
          twoDigitHex = do
            d1 <- choose (0,15) :: Gen Int
            d2 <- choose (0,15) :: Gen Int
            return (printf "\\x%x%X" d1 d2)
          nDigitHex = do
            zs <- listOf (elements "0")
            v <- choose (0,255) :: Gen Int
            return (printf "\\x{%s%x}" zs v)

erlTermParser :: Parser SimpleErlangTerm
erlTermParser = erlAtomParser
                <|> erlCharParser
                <|> erlStringParser
                <|> erlBinaryParser
                <|> try erlFloatParser
                <|> erlNaturalParser

erlAtomParser :: Parser SimpleErlangTerm
erlAtomParser =
  ErlAtom <$>
  (between (char '\'')
           (char '\'')
           (many (erlCharEscaped <|> noneOf "'"))
   <|>
   ((:) <$> lower <*> many erlNameChar))

erlNameChar :: Parser Char
erlNameChar = alphaNum <|> char '@' <|> char '_'

erlCharParser :: Parser SimpleErlangTerm
erlCharParser = ErlChar <$> (char '$' >> (erlCharEscaped <|> anyChar))

erlFloatParser :: Parser SimpleErlangTerm
erlFloatParser = do
  -- Parse a float as string, then use read :: Double to 'parse' the floating
  -- point value. Calculating by hand is complicated because of precision
  -- issues.
  sign <- option "" ((char '-' >> return "-") <|> (char '+' >> return ""))
  s1 <- many digit
  char '.'
  s2 <- many digit
  e <- do expSym <- choice [char 'e', char 'E']
          expSign <- option "" ((char '-' >> return "-") <|> (char '+' >> return "+"))
          expAbs <- many1 digit
          return ([expSym] ++ expSign ++ expAbs)
      <|> return ""
  return (ErlFloat (read (sign ++ s1 ++ "." ++ s2 ++ e)))

erlNaturalParser :: Parser SimpleErlangTerm
erlNaturalParser = do
  sign <- signParser
  dec <- decimalLiteral
  return $ ErlNatural $ sign * dec

signParser :: Parser Integer
signParser =
  (char '-' >> return (-1))
  <|> (char '+' >> return 1)
  <|> return 1

decimalLiteral :: Parser Integer
decimalLiteral =
   foldr (\radix acc ->
            (try (string (show radix ++ "#"))
             >> calcBE (toInteger radix) <$> many1 (erlDigits radix))
            <|> acc)
         (calcBE 10 <$> many1 (erlDigits 10))
         [2..36]
  where
    calcBE a = foldl (\acc d -> a * acc + d) 0
    erlDigits k = choice (take k digitParsers)
    digitParsers =
      -- create parsers that consume/match '0' .. '9' and "aA" .. "zZ" and return 0 .. 35
      map (\(cs,v) -> choice (char <$> cs) >> return v)
          (((pure <$> ['0' .. '9']) ++ zipWith ((++) `on` pure)
                                               ['a' .. 'z']
                                               ['A' .. 'Z'])
           `zip` [0..])

erlStringParser :: Parser SimpleErlangTerm
erlStringParser = do
  char '"'
  str <- many (erlCharEscaped <|> noneOf "\"")
  char '"'
  return (ErlString str)

erlCharEscaped :: Parser Char
erlCharEscaped =
  char '\\'
  >> (do char '^'
         choice (zipWith escapedChar ccodes creplacements)

      <|>
      do char 'x'
         (do ds <- between (char '{') (char '}') (fmap hexVal <$> many1 hexDigit)
             let val = foldl (\acc v -> acc * 16 + v) 0 ds
             return (toEnum val)
          <|>
          do x1 <- hexVal <$> hexDigit
             x2 <- hexVal <$> hexDigit;
             return (toEnum ((x1*16)+x2)))

      <|>
      do o1 <- octVal <$> octDigit
         (do o2 <- octVal <$>  octDigit
             (do o3 <- octVal <$>  octDigit
                 return (toEnum ((((o1*8)+o2)*8)+o3))
              <|>
              return (toEnum ((o1*8)+o2)))
          <|>
          return (toEnum o1))

      <|>
      choice (zipWith escapedChar codes replacements))
  where
    escapedChar code replacement = char code >> return replacement
    codes =
      ['0'   , 'b'  , 'd'  , 'e'  , 'f' , 'n' , 'r' , 's' , 't' , 'v' ,'\\','\"','\'']
    replacements =
      ['\NUL', '\BS','\DEL','\ESC','\FF','\LF','\CR','\SP','\HT','\VT','\\','\"','\'']
    ccodes =
      ['a' .. 'z'] ++ ['A' .. 'Z']
    creplacements =
      cycle ['\^A' .. '\^Z']
    hexVal v | v `elem` ['a' .. 'z'] = 0xA + (fromEnum v - fromEnum 'a')
             | v `elem` ['A' .. 'Z'] = 0xA + (fromEnum v - fromEnum 'A')
             | otherwise = fromEnum v - fromEnum '0'
    octVal = hexVal

erlBinaryParser :: Parser SimpleErlangTerm
erlBinaryParser =
  do string "<<"
     ErlString str <- option (ErlString "") erlStringParser
     string ">>"
     return (ErlBinary str)
