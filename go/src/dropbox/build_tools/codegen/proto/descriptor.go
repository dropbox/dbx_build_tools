package proto

import (
	"fmt"
	"path"

	"github.com/gogo/protobuf/protoc-gen-gogo/descriptor"
	"github.com/gogo/protobuf/protoc-gen-gogo/generator"
	plugin "github.com/gogo/protobuf/protoc-gen-gogo/plugin"
)

var (
	reservedMethodNames = map[string]struct{}{
		"Close": struct{}{},
	}
)

type Message struct {
	PkgDir  string
	PkgFile string

	FullName string

	File       *descriptor.FileDescriptorProto
	Descriptor *descriptor.DescriptorProto
}

type Enum struct {
	PkgDir  string
	PkgFile string

	FullName string

	File *descriptor.FileDescriptorProto
	Enum *descriptor.EnumDescriptorProto
}

type Comments struct {
	location *descriptor.SourceCodeInfo_Location
	children map[int32]*Comments
}

func NewCommentNode() *Comments {
	return &Comments{
		children: make(map[int32]*Comments),
	}
}

func (node *Comments) Add(location *descriptor.SourceCodeInfo_Location) {
	for _, index := range location.Path {
		child, ok := node.children[index]
		if !ok {
			child = NewCommentNode()
			node.children[index] = child
		}
		node = child
	}
	node.location = location
}

func (node *Comments) Get(path ...int32) (*descriptor.SourceCodeInfo_Location, bool) {
	var ok bool
	for _, index := range path {
		if node, ok = node.children[index]; !ok {
			return nil, false
		}
	}
	return node.location, node.location != nil
}

type Descriptors struct {
	Files map[string]*descriptor.FileDescriptorProto

	// Assumption: message and enum names are fully-qualified (starts with a '.')
	Messages map[string]*Message
	Enums    map[string]*Enum

	LocationByService         map[string]*descriptor.SourceCodeInfo_Location
	LocationByServiceByMethod map[string]map[string]*descriptor.SourceCodeInfo_Location

	ToGenerate []*descriptor.FileDescriptorProto
}

func ParseRequest(req *plugin.CodeGeneratorRequest) (*Descriptors, error) {
	mapping := &Descriptors{
		Files:                     make(map[string]*descriptor.FileDescriptorProto),
		Messages:                  make(map[string]*Message),
		Enums:                     make(map[string]*Enum),
		LocationByService:         make(map[string]*descriptor.SourceCodeInfo_Location),
		LocationByServiceByMethod: make(map[string]map[string]*descriptor.SourceCodeInfo_Location),
		ToGenerate:                nil,
	}

	for _, fd := range req.ProtoFile {
		mapping.Files[fd.GetName()] = fd

		pkgDir, pkgFile := path.Split(fd.GetName())
		if len(pkgDir) > 0 && pkgDir[len(pkgDir)-1] == '/' {
			pkgDir = pkgDir[:len(pkgDir)-1]
		}

		prefix := "." + fd.GetPackage() + "."
		err := addMessages(fd.MessageType, prefix, pkgDir, pkgFile, fd, mapping)
		if err != nil {
			return nil, err
		}
		err = addEnums(fd.EnumType, prefix, pkgDir, pkgFile, fd, mapping)
		if err != nil {
			return nil, err
		}

		commentNode := NewCommentNode()
		for _, location := range fd.GetSourceCodeInfo().GetLocation() {
			commentNode.Add(location)
		}

		for serviceIndex, service := range fd.Service {
			if location, ok := commentNode.Get(6, int32(serviceIndex)); ok {
				mapping.LocationByService[service.GetName()] = location
			}
			for methodIndex, method := range service.Method {
				if location, ok := commentNode.Get(6, int32(serviceIndex), 2, int32(methodIndex)); ok {
					locationByMethod, ok := mapping.LocationByServiceByMethod[service.GetName()]
					if !ok {
						locationByMethod = make(map[string]*descriptor.SourceCodeInfo_Location)
						mapping.LocationByServiceByMethod[service.GetName()] = locationByMethod
					}
					locationByMethod[method.GetName()] = location
				}

				methodName := generator.CamelCase(method.GetName())
				_, ok := reservedMethodNames[methodName]
				if ok {
					return nil, fmt.Errorf(
						"Cannot use %s as method name. %s is reserved.",
						method.GetName(),
						methodName)
				}
			}
		}
	}

	for _, name := range req.FileToGenerate {
		mapping.ToGenerate = append(mapping.ToGenerate, mapping.Files[name])
	}

	return mapping, nil
}

func (mapping *Descriptors) ServiceLocation(
	service *descriptor.ServiceDescriptorProto) *descriptor.SourceCodeInfo_Location {

	return mapping.LocationByService[service.GetName()]
}

func (mapping *Descriptors) MethodLocation(
	service *descriptor.ServiceDescriptorProto,
	method *descriptor.MethodDescriptorProto) *descriptor.SourceCodeInfo_Location {

	return mapping.LocationByServiceByMethod[service.GetName()][method.GetName()]
}

func addMessages(
	messages []*descriptor.DescriptorProto,
	prefix, pkgDir, pkgFile string,
	fd *descriptor.FileDescriptorProto,
	descriptors *Descriptors) error {

	for _, msg := range messages {
		fullName := prefix + msg.GetName()
		descriptors.Messages[fullName] = &Message{
			PkgDir:     pkgDir,
			PkgFile:    pkgFile,
			FullName:   fullName,
			File:       fd,
			Descriptor: msg,
		}
		newPrefix := prefix + msg.GetName() + "."
		err := addMessages(msg.NestedType, newPrefix,
			pkgDir, pkgFile, fd, descriptors)
		if err != nil {
			return err
		}
		err = addEnums(msg.EnumType, newPrefix, pkgDir, pkgFile, fd, descriptors)
		if err != nil {
			return err
		}
	}

	return nil
}

func addEnums(
	enums []*descriptor.EnumDescriptorProto,
	prefix, pkgDir, pkgFile string,
	fd *descriptor.FileDescriptorProto,
	descriptors *Descriptors) error {

	for _, enum := range enums {
		fullName := prefix + enum.GetName()
		descriptors.Messages[fullName] = &Message{
			PkgDir:  pkgDir,
			PkgFile: pkgFile,
			File:    fd,
		}

		descriptors.Enums[fullName] = &Enum{
			PkgDir:   pkgDir,
			PkgFile:  pkgFile,
			FullName: fullName,
			File:     fd,
			Enum:     enum,
		}
	}

	return nil
}
