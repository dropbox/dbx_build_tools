package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"flag"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var (
	constantTimestamp = time.Unix(1000000000, 0)
)

func main() {
	manifest := flag.String("manifest", "", "manifest file")
	symlink := flag.String("symlink", "", "manifest file")
	compression := flag.Int(
		"compression",
		-1,
		"if non-negative, override the default the compression level",
	)
	packageDirPrefix := flag.String("package-dir", "", "path prefix")
	stripPrefix := flag.String(
		"strip-prefix",
		"",
		"removes this prefix from every input before writing it to the given package-dir",
	)
	outputFile := flag.String("output", "", "path to write output tar file")
	flag.Parse()

	if *manifest == "" {
		log.Fatal("-manifest must be set")
	}
	if *symlink == "" {
		log.Fatal("-symlink must be set")
	}
	if *packageDirPrefix == "" {
		log.Fatal("-package-dir must be set")
	}
	packageDir := strings.TrimPrefix(*packageDirPrefix, "/")
	if !strings.HasPrefix(packageDir, "./") {
		packageDir = "./" + packageDir
	}

	if *outputFile == "" {
		log.Fatal("-output must be set")
	}

	outFile, err := os.Create(*outputFile)
	if err != nil {
		log.Fatal(err)
	}

	defer outFile.Close()

	var tarWriter *tar.Writer
	if strings.HasSuffix(*outputFile, "gz") {
		gzipCompression := gzip.BestCompression
		if *compression >= 0 {
			gzipCompression = *compression
		}
		gzipWriter, err := gzip.NewWriterLevel(outFile, gzipCompression)
		if err != nil {
			log.Fatal(err)
		}
		defer gzipWriter.Close()
		tarWriter = tar.NewWriter(gzipWriter)
		defer tarWriter.Close()
	} else {
		tarWriter = tar.NewWriter(outFile)
	}
	defer tarWriter.Close()

	manifestEntries, err := readManifest(*manifest)
	if err != nil {
		log.Fatal(err)
	}
	symlinkEntries, err := readSymlinks(*symlink)
	if err != nil {
		log.Fatal(err)
	}

	createdDirs := make(map[string]struct{}, 0)
	for _, manifest := range manifestEntries {
		dst := rewriteDestination(manifest.shortDest, symlinkEntries, packageDir, *stripPrefix)

		// empty file
		if manifest.src == "" {
			header := &tar.Header{
				Name:    dst,
				Size:    0,
				Mode:    int64(0444),
				ModTime: constantTimestamp,
			}
			if err := tarWriter.WriteHeader(header); err != nil {
				log.Fatal(err)
			}
			var b bytes.Buffer
			if _, err := io.Copy(tarWriter, &b); err != nil {
				log.Fatal(err)
			}
			continue
		}

		stat, err := os.Stat(manifest.src)
		if err != nil {
			log.Printf("failed to stat file %q: %v", manifest.src, err)
		}

		if err := maybeCreateDirectories(dst, createdDirs, tarWriter); err != nil {
			log.Fatal(err)
		}
		header := &tar.Header{
			Name:    dst,
			Size:    stat.Size(),
			Mode:    int64(stat.Mode()),
			ModTime: constantTimestamp,
		}
		if err := tarWriter.WriteHeader(header); err != nil {
			log.Fatal(err)
		}

		f, err := os.Open(manifest.src)
		if err != nil {
			log.Fatal(err)
		}
		if _, err := io.Copy(tarWriter, f); err != nil {
			log.Fatal(err)
		}
		f.Close()
	}
}

func maybeCreateDirectories(filePath string, alreadyCreated map[string]struct{}, tarWriter *tar.Writer) error {
	newDirs := make([]string, 0)
	dirName := filepath.Dir(filePath)
	for dirName != "." {
		if _, ok := alreadyCreated[dirName]; ok {
			break
		}
		alreadyCreated[dirName] = struct{}{}
		newDirs = append(newDirs, dirName)
		dirName = filepath.Dir(dirName)
	}
	for i := len(newDirs) - 1; i >= 0; i-- {
		header := &tar.Header{
			Name:     newDirs[i],
			Typeflag: tar.TypeDir,
			Mode:     int64(0755),
			ModTime:  constantTimestamp,
		}
		if err := tarWriter.WriteHeader(header); err != nil {
			return err
		}
	}
	return nil
}

func rewriteDestination(shortDest string, symlinkEntries []symlinkEntry, packageDir string, stripPrefix string) string {
	for _, entry := range symlinkEntries {
		if shortDest == entry.dst {
			shortDest = entry.src
			continue
		}
		if strings.HasPrefix(shortDest, entry.dst) {
			shortDest = entry.src + strings.TrimPrefix(shortDest, entry.dst)
			continue
		}
	}
	if stripPrefix != "" {
		shortDest = strings.TrimPrefix(shortDest, stripPrefix)
	}
	return filepath.Join(strings.TrimPrefix(packageDir, "/"), shortDest)
}

type manifestEntry struct {
	shortDest string
	src       string
}

func readManifest(manifestFile string) ([]manifestEntry, error) {
	file, err := os.Open(manifestFile)
	if err != nil {
		return nil, err
	}

	defer file.Close()
	scanner := bufio.NewScanner(file)
	var entries []manifestEntry
	for scanner.Scan() {
		line := scanner.Text()
		components := strings.SplitN(line, "\x00", 2)
		var src string
		if len(components) == 2 {
			src = strings.TrimSpace(components[1])
		}
		entries = append(entries, manifestEntry{
			shortDest: components[0],
			src:       src,
		})
	}
	return entries, nil
}

type symlinkEntry struct {
	src string
	dst string
}

func readSymlinks(symlinkFile string) ([]symlinkEntry, error) {
	file, err := os.Open(symlinkFile)
	if err != nil {
		return nil, err
	}

	defer file.Close()
	scanner := bufio.NewScanner(file)
	var entries []symlinkEntry
	for scanner.Scan() {
		line := scanner.Text()
		components := strings.SplitN(line, "\x00", 2)
		var dst string
		if len(components) == 2 {
			dst = strings.TrimSpace(components[1])
		}
		entries = append(entries, symlinkEntry{
			src: components[0],
			dst: dst,
		})
	}
	return entries, nil
}
