package main

import (
	"embed"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
)

// Задаём дефолт на случай, если ldflags не передали
var BuildTag = "test"

//go:embed install.sh steps
var embeddedFiles embed.FS

func main() {
	var version string
	var enableGrafana bool
	flag.StringVar(&version, "version", "", "override version tag (optional)")
	flag.BoolVar(&enableGrafana, "grafana", false, "enable Grafana installation (optional)")
	flag.Parse()

	// Если флаг пустой — используем вшитый BuildTag
	if version == "" {
		version = BuildTag
	}

	tmpDir, err := os.MkdirTemp("", "midas-install-*")
	if err != nil {
		fmt.Printf("❌ Error creating temp directory: %v\n", err)
		os.Exit(1)
	}
	defer os.RemoveAll(tmpDir)

	fmt.Println("📦 Unpacking resources to:", tmpDir)

	err = fs.WalkDir(embeddedFiles, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		data, err := embeddedFiles.ReadFile(path)
		if err != nil {
			return err
		}
		target := filepath.Join(tmpDir, path)
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}
		return os.WriteFile(target, data, 0755)
	})
	if err != nil {
		fmt.Printf("❌ Error unpacking files: %v\n", err)
		os.Exit(1)
	}

	installScriptPath := filepath.Join(tmpDir, "install.sh")
	if _, err := os.Stat(installScriptPath); os.IsNotExist(err) {
		fmt.Println("❌ Error: install.sh not found after unpacking")
		os.Exit(1)
	}
	_ = os.Chmod(installScriptPath, 0755)

	fmt.Println("🚀 Running install.sh")
	fmt.Println("📌 MidasCore version:", version)

	cmd := exec.Command("bash", installScriptPath)
	cmd.Env = append(os.Environ(),
		"MIDAS_VERSION="+version,
		fmt.Sprintf("MIDAS_ENABLE_GRAFANA=%v", enableGrafana),
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	cmd.Dir = tmpDir

	if err := cmd.Run(); err != nil {
		fmt.Printf("❌ Error executing install.sh: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("✅ Installation completed successfully!")
}
