package main

import (
	"bufio"
	"crypto/sha256"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"dropbox/runfiles"
)

const (
	workerCount = 100

	// In order to make our sqfs files reproducible, we pick an arbitrary
	// unix timestamp to use for all file modification times and the
	// sqfs creation time.
	constantTimestampInt int64 = 1000000000

	// In more reproducibility fun across machines, we need to normalize
	// the file modes. We'll simply assume that directories should be given
	// a 0775 mode, while files should only be readable by everyone, and
	// writable by no one. We preserve the executable bits.
	directoryMode               = 0755
	fileModeOrMask  os.FileMode = os.FileMode(syscall.S_IRUSR) | syscall.S_IRGRP | syscall.S_IROTH
	fileModeAndMask os.FileMode = ^(os.FileMode(syscall.S_IWOTH) | syscall.S_IWUSR | syscall.S_IWGRP)
)

var (
	verbose = flag.Bool("verbose", false, "turn on verbose logging")
)

type manifestEntry struct {
	shortDest string
	src       string
}

func contentAddressableHash(filePath string, stat os.FileInfo) (string, error) {
	f, err := os.Open(filePath)
	if err != nil {
		return "", err
	}
	defer f.Close()
	hasher := sha256.New()
	if _, err := io.Copy(hasher, f); err != nil {
		return "", err
	}
	// include file mode in hash as we will be using this to create hardlinks - multiple hardlinks of the same file must have the same mode/metadata
	hash := hasher.Sum([]byte(fmt.Sprintf("%s", stat.Mode())))
	return fmt.Sprintf("%x", hash), nil
}

func copyFile(src, dst string) (finalErr error) {
	srcFile, err := os.Open(src)
	if err != nil {
		finalErr = err
		return
	}
	defer srcFile.Close()
	dstFile, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0644 /* does not matter, we need to chmod after this to get around umask */)
	if err != nil {
		finalErr = err
		return
	}
	defer func() {
		if closeErr := dstFile.Close(); closeErr != nil && finalErr == nil {
			finalErr = closeErr
		}
	}()
	if _, err := io.Copy(dstFile, srcFile); err != nil {
		finalErr = err
		return
	}
	return
}

func readManifest(manifestFile string) ([]*manifestEntry, error) {
	if *verbose {
		start := time.Now()
		defer func() {
			log.Printf("Reading manifest takes %s", time.Since(start))
		}()
	}
	file, err := os.Open(manifestFile)
	if err != nil {
		return nil, err
	}

	defer file.Close()
	scanner := bufio.NewScanner(file)
	var entries []*manifestEntry
	for scanner.Scan() {
		line := scanner.Text()
		components := strings.SplitN(line, "\x00", 2)
		var src string
		if len(components) == 2 {
			src = strings.TrimSpace(components[1])
		}
		entries = append(entries, &manifestEntry{
			shortDest: components[0],
			src:       src,
		})
	}
	return entries, nil
}

func prepareContentAddressableSrcs(entries []*manifestEntry, contentsDir string) (map[string]string, error) {
	if *verbose {
		start := time.Now()
		defer func() {
			log.Printf("Creating content addressable output tree takes %s", time.Since(start))
		}()
	}
	var lock sync.Mutex
	contentMap := map[string]string{}
	srcChan := make(chan string, workerCount)
	defer func() {
		for _ = range srcChan {
		} // drain in case we got error and terminated early
	}()
	go func(lock *sync.Mutex) {
		for _, entry := range entries {
			lock.Lock()
			if _, ok := contentMap[entry.src]; !ok {
				contentMap[entry.src] = ""
				lock.Unlock()
				srcChan <- entry.src
			} else {
				lock.Unlock()
			}
		}
		close(srcChan)
	}(&lock)
	var wg sync.WaitGroup
	errChan := make(chan error)
	for i := 0; i < workerCount; i++ {
		wg.Add(1)
		go func(lock *sync.Mutex, wg *sync.WaitGroup) {
			defer wg.Done()
			for src := range srcChan {
				if src == "" {
					continue
				}
				stat, err := os.Stat(src)
				if err != nil {
					errChan <- err
					return
				}
				if stat.IsDir() {
					errChan <- fmt.Errorf("A raw target pointing to a directory was detected: %s\nPlease use a filegroup instead.", src)
					return
				}
				hash, err := contentAddressableHash(src, stat)
				if err != nil {
					errChan <- err
					return
				}
				hashDir := filepath.Join(contentsDir, hash[:2])
				hashPath := filepath.Join(hashDir, hash[2:])
				if err := copyFile(src, hashPath); err != nil {
					if os.IsNotExist(err) {
						// not using our own mkdirAllStable as this dir is ephemeral and will disappear
						// NOTE we call mkdirall after attempting to create the file, to optimistically save on syscalls
						if err := os.MkdirAll(hashDir, 0755); err != nil {
							errChan <- err
							return
						}
						err = copyFile(src, hashPath)
					}
					if err != nil {
						if !os.IsExist(err) {
							errChan <- err
							return
						}
						lock.Lock()
						contentMap[src] = hashPath
						lock.Unlock()
						continue
					}
				}

				// need explicit chmod instead of just setting permissions when creating the file,
				// to get around umask
				newMode := stat.Mode()&fileModeAndMask | fileModeOrMask
				if err := os.Chmod(hashPath, newMode); err != nil {
					errChan <- err
					return
				}
				if err := fixTime(hashPath); err != nil {
					errChan <- err
					return
				}
				lock.Lock()
				contentMap[src] = hashPath
				lock.Unlock()
			}
		}(&lock, &wg)
	}
	go func() {
		wg.Wait()
		close(errChan)
	}()
	var consolidatedError error
	for err := range errChan {
		consolidatedError = fmt.Errorf("%s\n%s", consolidatedError, err)
	}
	if consolidatedError != nil {
		return nil, consolidatedError
	}
	return contentMap, nil
}

func linkOutputTree(entries []*manifestEntry, scratchDir string, contentMap map[string]string) error {
	if *verbose {
		start := time.Now()
		defer func() {
			log.Printf("Linking output tree takes %s", time.Since(start))
		}()
	}

	type workItem struct {
		startIndex int // inclusive
		endIndex   int // exclusive
	}
	workChan := make(chan *workItem, workerCount)
	defer func() {
		for _ = range workChan {
		} // drain in case we got error and terminated early
	}()
	go func() {
		length := len(entries)
		// bound the number of work items we create, to avoid sending (in large cases) millions
		// of items through a channel
		const maxWorkItems = 10000
		step := length / maxWorkItems
		if step < 1 {
			step = 1
		}
		for i := 0; i < length; i += step {
			end := i + step
			if end > length {
				end = length
			}
			workChan <- &workItem{
				startIndex: i,
				endIndex:   end,
			}
		}
		close(workChan)
	}()
	var wg sync.WaitGroup
	errChan := make(chan error)
	defer func() {
		for _ = range errChan {
		} // may be needed if we run into validation error below
	}()
	for i := 0; i < workerCount; i++ {
		wg.Add(1)
		go func(wg *sync.WaitGroup) {
			defer wg.Done()
			for work := range workChan {
				for i := work.startIndex; i < work.endIndex; i++ {
					entry := entries[i]
					dest := filepath.Join(scratchDir, entry.shortDest)
					// NOTE: in order to reduce syscalls, we explicitly optimistically try to create
					// the file first, and only if that fails, create parent directories
					if entry.src == "" {
						emptyFile, err := os.Create(dest)
						if err != nil {
							if !os.IsNotExist(err) {
								errChan <- err
								return
							}
							if err := mkdirAllStable(filepath.Dir(dest)); err != nil {
								errChan <- err
								return
							}
							emptyFile, err = os.Create(dest)
							if err != nil {
								errChan <- err
								return
							}
						}
						if err := emptyFile.Close(); err != nil {
							errChan <- err
							return
						}
						// chmod needed instead of setting correct permissions on create, to bypass umask
						if err := os.Chmod(dest, 0444); err != nil {
							errChan <- err
							return
						}
						if err := fixTime(dest); err != nil {
							errChan <- err
							return
						}
					} else {
						if err := os.Link(contentMap[entry.src], dest); err != nil {
							if !os.IsNotExist(err) {
								errChan <- err
								return
							}
							if err := mkdirAllStable(filepath.Dir(dest)); err != nil {
								errChan <- err
								return
							}
							if err := os.Link(contentMap[entry.src], dest); err != nil {
								errChan <- err
								return
							}
						}
					}
				}
			}
		}(&wg)
	}
	go func() {
		wg.Wait()
		close(errChan)
	}()
	{
		// validate input. do this while the background workers are doing work, to save time, as going
		// through all entries for large sqfs can be slow
		destMap := make(map[string]struct{})
		for _, entry := range entries {
			if _, ok := destMap[entry.shortDest]; ok {
				return fmt.Errorf("Detected duplicate output %s", entry.shortDest)
			}
			destMap[entry.shortDest] = struct{}{}
		}
	}
	var consolidatedError error
	for err := range errChan {
		consolidatedError = fmt.Errorf("%s\n%s", consolidatedError, err)
	}
	return consolidatedError
}

func prepareOutputTree(manifestFile, outputDir string) error {
	if *verbose {
		start := time.Now()
		defer func() {
			log.Printf("Preparing output tree takes %s", time.Since(start))
		}()
	}
	contentsPath := filepath.Join(outputDir, ".contents")
	defer os.RemoveAll(contentsPath) // needed otherwise we'd also ship this .contents directory in the final sqfs
	entries, err := readManifest(manifestFile)
	if err != nil {
		return err
	}

	contentMap, err := prepareContentAddressableSrcs(entries, contentsPath)
	if err != nil {
		return err
	}
	if err := linkOutputTree(entries, outputDir, contentMap); err != nil {
		return err
	}

	return nil
}

func createSymlinks(symlinkManifest, scratchDir string) error {
	if *verbose {
		start := time.Now()
		defer func() {
			log.Printf("Symlink takes %s", time.Since(start))
		}()
	}
	symlinkManifestFile, err := os.Open(symlinkManifest)
	if err != nil {
		return err
	}

	defer symlinkManifestFile.Close()
	scanner := bufio.NewScanner(symlinkManifestFile)
	for scanner.Scan() {
		line := scanner.Text()
		components := strings.SplitN(line, "\x00", 2)
		if len(components) != 2 {
			return fmt.Errorf("Unexpected symlink line: %s", line)
		}
		linkPath := components[0]
		linkTarget := components[1]
		// Strip any trailing slashes in case we're linking directories.
		linkPath = strings.TrimRight(linkPath, "/")

		// Calculate the relative path so the symlink works correctly.
		relTargetPath, err := filepath.Rel(filepath.Dir(linkPath), linkTarget)
		if err != nil {
			return fmt.Errorf("Cannot compute relative path from %s to %s", linkTarget, linkPath)
		}

		absLinkPath := filepath.Join(scratchDir, linkPath)

		if err := mkdirAllStable(filepath.Dir(absLinkPath)); err != nil {
			return err
		}

		if err := os.Symlink(relTargetPath, absLinkPath); err != nil {
			return err
		}
		if err := fixTime(absLinkPath); err != nil {
			return err
		}
	}
	return nil
}

var directoriesCreatedChan = make(chan string)

// similar to os.MkdirAll but sets the right utime all the way
func mkdirAllStable(path string) error {
	if path == "" {
		return fmt.Errorf("Got empty path, should be impossible")
	}
	if err := os.Mkdir(path, directoryMode); err != nil {
		if os.IsExist(err) {
			return nil
		}
		if !os.IsNotExist(err) {
			return err
		}
		if err := mkdirAllStable(filepath.Dir(path)); err != nil {
			return err
		}
		if err := os.Mkdir(path, directoryMode); err != nil {
			if !os.IsExist(err) {
				return err
			}
		}
	}
	// chmod again to ensure the permission is right (otherwise umask may mess with us)
	if err := os.Chmod(path, directoryMode); err != nil {
		return err
	}
	// timestamp is modified at end of program as the filesystem changes the timestamp each time a file is added to a directory
	directoriesCreatedChan <- path
	return nil
}

var utimeSpec = []unix.Timeval{
	{
		Sec: constantTimestampInt,
	},
	{
		Sec: constantTimestampInt,
	},
}

// unfortunately, golang os.Chtimes unconditionally follows symlinks, so we must use syscalls ourselves
func fixTime(path string) error {
	if err := unix.Lutimes(path, utimeSpec); err != nil {
		return err
	}
	return nil
}

func setCapability(capabilityFilePath, scratchDir string) error {
	if *verbose {
		start := time.Now()
		defer func() {
			log.Printf("setcap takes %s", time.Since(start))
		}()
	}
	var capabilityArgs []string
	capabilityFile, err := os.Open(capabilityFilePath)
	if err != nil {
		return err
	}

	defer capabilityFile.Close()
	scanner := bufio.NewScanner(capabilityFile)
	for scanner.Scan() {
		line := scanner.Text()
		components := strings.SplitN(line, "\x00", 2)
		if len(components) != 2 {
			return fmt.Errorf("Unexpected capability line: %s", line)
		}
		filePath := components[0]
		capabilityStr := components[1]
		capabilityArgs = append(capabilityArgs, capabilityStr, filepath.Join(scratchDir, filePath))
	}

	cmd := exec.Command("/sbin/setcap", capabilityArgs...)
	if output, err := cmd.CombinedOutput(); err != nil {
		return err
	} else if len(output) != 0 {
		// There are lots of errors that setcap returns an exit code of 0 for, so we check if it
		// emitted any output, and assume that if it did, some error occurred.
		// For example, applying a capability to a non-existent file gives an exit code of 0.
		return fmt.Errorf("setcap exited with output: %s", string(output))
	}
	return nil
}

func main() {
	manifest := flag.String("manifest", "", "manifest file")
	outputSqfs := flag.String("output", "", "path to write output sqfs file")
	capability := flag.String("capability-map", "", "capability file, if any")
	symlink := flag.String("symlink", "", "symlink file")
	scratch := flag.String("scratch-dir", "/tmp/sqfs_pkg", "path to write temporary sqfs files")
	blockSizeKb := flag.Int("block-size-kb", 0, "sqfs block size (in KB)")
	compressionAlgo := flag.String("compression-algo", "", "compression algorithm")
	compressionLevel := flag.Int("compression-level", 0, "compression level")
	flag.Parse()
	if *verbose {
		start := time.Now()
		defer func() {
			log.Printf("End to end takes %s", time.Since(start))
		}()
	}
	directoriesCreated := []string{*scratch}
	directoriesCreatedDoneChan := make(chan struct{})
	go func() {
		defer close(directoriesCreatedDoneChan)
		for dir := range directoriesCreatedChan {
			directoriesCreated = append(directoriesCreated, dir)
		}
	}()
	if err := prepareOutputTree(*manifest, *scratch); err != nil {
		log.Fatal("failed to prepare manifest", err)
	}

	if err := createSymlinks(*symlink, *scratch); err != nil {
		log.Fatal("failed to create symlinks", err)
	}
	close(directoriesCreatedChan)
	<-directoriesCreatedDoneChan
	for _, dir := range directoriesCreated {
		if err := fixTime(dir); err != nil {
			log.Fatal(err)
		}
	}

	if *capability != "" {
		if err := setCapability(*capability, *scratch); err != nil {
			log.Fatal("failed to set capability", err)
		}
	}

	args := []string{
		runfiles.MustDataPath("@com_github_plougher_squashfs_tools//mksquashfs"), *scratch, *outputSqfs,
		"-no-progress",
		"-noappend",
		"-no-fragments",
		"-no-duplicates",
		"-processors",
		fmt.Sprintf("%d", runtime.NumCPU()),
		"-fstime",
		fmt.Sprintf("%d", constantTimestampInt),
	}
	if *blockSizeKb != 0 {
		args = append(args, "-b", fmt.Sprintf("%dK", *blockSizeKb))
	}
	if *compressionAlgo != "" {
		args = append(args, "-comp", *compressionAlgo)
	}
	if *compressionLevel != 0 && *compressionAlgo != "lz4" {
		args = append(args, "-Xcompression-level", fmt.Sprintf("%d", *compressionLevel))
	}

	cmd := exec.Command(runfiles.MustDataPath("@dbx_build_tools//build_tools/chronic"), args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Fatal(err)
	}
}
