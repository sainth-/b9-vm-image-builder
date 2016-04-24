-- | Implement 'B9IO' to do the real-thing(tm).
module B9.B9IO.Impl where

import           B9.Common
import           B9.B9IO
import qualified B9.B9Monad             as B9Monad
import           B9.DiskImages
import           B9.ExecEnv
import           B9.FileSystems
import           B9.FileSystemsImpl
import qualified B9.LibVirtLXC          as LXC
import           B9.Logging
import           B9.PartitionTable
import           B9.QemuImg
import           B9.RepositoryIO
import           B9.ShellScript
import qualified Conduit                as C
import qualified Data.ByteString        as B
import qualified Data.Conduit.Binary    as CB
import           System.IO
import           System.Random

-- | Execute a 'B9IO' Program in the 'B9' monad.
executeIoProg :: IoProgram a -> B9Monad.B9 a
executeIoProg = runB9IO go
  where
    go :: Action a -> B9Monad.B9 a
    go (LogMessage l s n) = do
        logMsg l s
        return n
    go (GetBuildDir k) = do
        b <- B9Monad.getBuildDir
        return (k b)
    go (GetBuildId n) = do
        b <- B9Monad.getBuildId
        return (n b)
    go (GetBuildDate k) = do
        d <- B9Monad.getBuildDate
        return (k d)
    go (MkTemp prefix k) = do
        b <- B9Monad.getBuildDir
        liftIO $ createDirectoryIfMissing True b
        go (MkTempIn b prefix k)
    go (MkTempIn parent prefix k) = do
        let prefix' = takeFileName prefix
        suffix <- liftIO $ replicateM 10 (randomRIO ('A', 'Z'))
        liftIO $ createDirectoryIfMissing True parent
        parentAbs <- liftIO $ makeAbsolute parent
        return (k (parentAbs </> prefix' ++ "-" ++ suffix))
    go (MkDir d n) = do
        liftIO $ createDirectoryIfMissing True d
        return n
    go (EnsureParentDir p k) = do
        let d = takeDirectory p
            f = takeFileName p
        liftIO $ createDirectoryIfMissing True d
        dAbs <- liftIO $ makeAbsolute d
        return (k (dAbs </> f))
    go (MkTempDir prefix k) = do
        b <- B9Monad.getBuildDir
        go (MkTempDirIn b prefix k)
    go (MkTempDirIn parent prefix k) = do
        suffix <- liftIO $ replicateM 10 (randomRIO ('A', 'Z'))
        let prefix' = takeFileName prefix
            dirName = parent </> prefix' ++ "-" ++ suffix <.> "d"
        liftIO $ createDirectoryIfMissing True dirName
        dirNameAbs <- liftIO $ makeAbsolute dirName
        return (k dirNameAbs)
    go (Copy s d n) = do
        liftIO $ copyFile s d
        return n
    go (CopyDir s d n) = do
        exists <- liftIO $ doesDirectoryExist d
        when exists (liftIO $ removeDirectoryRecursive d)
        B9Monad.cmdRaw "cp" ["-r", s, d]
        return n
    go (MoveFile s d n) = do
        B9Monad.cmdRaw "mv" [s, d]
        return n
    go (MoveDir s d n) = do
        exists <- liftIO $ doesDirectoryExist d
        when exists (liftIO $ removeDirectoryRecursive d)
        B9Monad.cmdRaw "mv" [s, d]
        return n
    go (GetParentDir f k) = return $ k (takeDirectory f)
    go (ReadFileSize f k) = do
        s <- liftIO $ withFile f ReadMode hFileSize
        return $ k s
    go (GetRealPath f k) = do
        f' <- liftIO $ makeAbsolute f
        return $ k f'
    go (GetFileName f k) = return $ k (takeFileName f)
    go (ReadContentFromFile f k) = do
        c <- liftIO (B.readFile f)
        return (k c)
    go (WriteContentToFile f c n) = do
        traceL "writing:" (unpackUtf8 c)
        liftIO $ B.writeFile f c
        return n
    go (CreateFileSystem dst fs srcDir files n) = do
        createFSWithFiles dst fs srcDir files
        return n
    go (ResizeFileSystem f r t n) = do
        resizeFS r f t
        return n
    go (ConvertVmImage s st d dt n) = do
        convertImageType s st d dt
        return n
    go (ResizeVmImage i s u t n) = do
        resizeImage (ImageSize s u) i t
        return n
    go (ExtractPartition p@(MBRPartition partIndex) s d n) = do
        (start,len) <- liftIO $ getPartition p s
        traceL
            "extracting MBR partition"
            partIndex
            "starting at"
            start
            "with a length of"
            len
            "(bytes) from"
            s
            "to"
            d
        liftIO
            (C.runResourceT
                 ((CB.sourceFileRange
                       s
                       (Just (fromIntegral start))
                       (Just (fromIntegral len))) C.$$
                  (CB.sinkFile d)))
        return n
    go (ImageRepoLookup s k) = do
        si <- getLatestSharedImageByNameFromCache s
        src <- getSharedImageCachedFilePath si
        return $ k (si, src)
    go (ImageRepoPublish f t sn n) = do
        let i = Image f t Ext4 -- TODO the file system should not be a parameter
        void $ shareImage i sn
        return n
    go (ExecuteInEnv e s d i n) = do
        let env = ExecEnv (e ^. execEnvTitle) i d (e ^. execEnvLimits)
        res <- LXC.runInEnvironment env s
        unless
            res
            (fail $
             printf
                 "CONTAINER EXECUTION ERROR!\n== Failed to execute this script: == \n================================================================================\nIn that environment: %s\n"
                 (toBash $ toCmds s)
                 (show env))
        return n
