import Foundation
import PathKit

// MARK: - PBXProj.Objects Extension (Public)

public extension PBXProj.Objects {

    /// Returns all the targets with the given name.
    ///
    /// - Parameter name: target name.
    /// - Returns: all existing targets with the given name.
    public func targets(named name: String) -> [PBXTarget] {
        var targets: [PBXTarget] = []
        targets.append(contentsOf: Array(nativeTargets.values) as [PBXTarget])
        targets.append(contentsOf: Array(legacyTargets.values) as [PBXTarget])
        targets.append(contentsOf: Array(aggregateTargets.values) as [PBXTarget])
        return targets.filter { $0.name == name }
    }

    /// Retruns target's sources build phase.
    ///
    /// - Parameter target: target object.
    /// - Returns: target's sources build phase, if found.
    public func sourcesBuildPhase(target: PBXTarget) -> PBXSourcesBuildPhase? {
        return sourcesBuildPhases.first(where: { target.buildPhases.contains($0.key) })?.value
    }

    /// Returns all files in target's sources build phase.
    ///
    /// - Parameter target: target object.
    /// - Returns: all files in target's sources build phase, or empty array if sources build phase is not found.
    public func sourceFiles(target: PBXTarget) -> [PBXFileElement] {
        return sourcesBuildPhase(target: target)?.files
            .flatMap({ buildFiles[$0]?.fileRef })
            .flatMap(getFileElement(reference:)) ?? []
    }

    /// Returns group with the given name contained in the given parent group and its reference.
    ///
    /// - Parameter groupName: group name.
    /// - Parameter inGroup: parent group.
    /// - Returns: group with the given name contained in the given parent group and its reference.
    public func group(named groupName: String, inGroup: PBXGroup) -> (String, PBXGroup)? {
        let children = inGroup.children
        return groups.first(where: {
            children.contains($0.key) && ($0.value.name == groupName || $0.value.path == groupName)
        })
    }

    /// Adds new group with the give name to the given parent group.
    /// Group name can be a path with components separated by `/`.
    /// Will create new groups for intermediate path components or use existing groups.
    /// Returns all new or existing groups in the path and their references.
    ///
    /// - Parameters:
    ///   - groupName: group name, can be a path with components separated by `/`
    ///   - toGroup: parent group
    ///   - options: additional options, default is empty set.
    /// - Returns: all new or existing groups in the path and their references.
    public func addGroup(named groupName: String, to toGroup: PBXGroup, options: GroupAddingOptions = []) -> [(String, PBXGroup)] {
        return addGroups(groupName.components(separatedBy: "/"), to: toGroup, options: options)
    }

    private func addGroups(_ groupNames: [String], to toGroup: PBXGroup, options: GroupAddingOptions) -> [(String, PBXGroup)] {
        guard !groupNames.isEmpty else { return [] }
        let newGroup = createOrGetGroup(named: groupNames[0], in: toGroup, options: options)
        return [newGroup] + addGroups(Array(groupNames.dropFirst()), to: newGroup.1, options: options)
    }

    private func createOrGetGroup(named groupName: String, in parentGroup: PBXGroup, options: GroupAddingOptions) -> (String, PBXGroup) {
        if let existingGroup = group(named: groupName, inGroup: parentGroup) {
            return existingGroup
        }

        let newGroup = PBXGroup(
            children: [],
            sourceTree: .group,
            name: groupName,
            path: options.contains(.withoutFolder) ? nil : groupName
        )
        let reference = generateReference(newGroup, groupName)
        addObject(newGroup, reference: reference)
        parentGroup.children.append(reference)
        return (reference, newGroup)
    }

    /// Adds file at the give path to the project or returns existing file and its reference.
    ///
    /// - Parameters:
    ///   - filePath: path to the file
    ///   - sourceTree: file source tree, default is `.group`.
    ///   - name: file name, by default gets file name from the path
    /// - Returns: new or existing file and its reference.
    public func addFile(at filePath: Path) throws -> (String, PBXFileReference) {
        guard filePath.isFile else { throw XCodeProjEditingError.notAFile(path: filePath) }

        if let existingFileReference = fileReferences.first(where: { $0.value.path == filePath.string }) {
            return existingFileReference
        }

        let fileReference = PBXFileReference(
            sourceTree: .group,
            name: filePath.lastComponent,
            explicitFileType: PBXFileReference.fileType(path: filePath),
            lastKnownFileType: PBXFileReference.fileType(path: filePath),
            path: filePath.string
        )
        let reference = generateReference(fileReference, filePath.string)
        addObject(fileReference, reference: reference)
        return (reference, fileReference)
    }

    /// Adds file to the given group.
    /// If group already contains file with given reference method does nothing.
    ///
    /// - Parameter group: group to add file to
    /// - Parameter reference: file reference
    public func addFile(toGroup group: PBXGroup, reference: String) {
        guard !group.children.contains(reference) else { return }
        group.children.append(reference)
    }

    /// Adds file to the given target's sources build phase or returns existing build file and its reference.
    /// If target's sources build phase can't be found returns nil.
    ///
    /// - Parameter target: target obejct
    /// - Parameter reference: file reference
    /// - Returns: new or existing build file and its reference
    public func addBuildFile(toTarget target: PBXTarget, reference: String) -> (String, PBXBuildFile)? {
        guard let sourcesBuildPhase = sourcesBuildPhase(target: target) else { return nil }
        if let existingBuildFile = buildFiles.first(where: { $0.value.fileRef == reference }) {
            return existingBuildFile
        }

        let buildFile = PBXBuildFile(fileRef: reference)
        let reference = generateReference(buildFile, reference)
        addObject(buildFile, reference: reference)
        sourcesBuildPhase.files.append(reference)
        return (reference, buildFile)
    }

}

public struct GroupAddingOptions: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
    /// Create group without reference to folder
    static let withoutFolder    = GroupAddingOptions(rawValue: 1 << 0)
}

public enum XCodeProjEditingError: Error, CustomStringConvertible {
    case notAFile(path: Path)

    public var description: String {
        switch self {
        case .notAFile(let path):
            return "\(path) is not a file path"
        }
    }
}

// MARK: - PBXProj.Objects Extension (Internal)

extension PBXProj.Objects {
    
    /// Returns the file name from a build file reference.
    ///
    /// - Parameter buildFileReference: file reference.
    /// - Returns: build file name.
    func fileName(buildFileReference: String) -> String? {
        guard let buildFile: PBXBuildFile = buildFiles.getReference(buildFileReference),
            let fileReference = buildFile.fileRef else {
                return nil
        }
        return fileName(fileReference: fileReference)
    }
    
    /// Returns the file name from a file reference.
    ///
    /// - Parameter fileReference: file reference.
    /// - Returns: file name.
    func fileName(fileReference: String) -> String? {
        guard let fileElement = getFileElement(reference: fileReference) else {
            return nil
        }
        return fileElement.name ?? fileElement.path
    }
    
    /// Returns the configNamefile reference.
    ///
    /// - Parameter configReference: reference of the XCBuildConfiguration.
    /// - Returns: config name.
    func configName(configReference: String) -> String? {
        return buildConfigurations[configReference]?.name
    }
    
    /// Returns the build phase a file is in.
    ///
    /// - Parameter reference: reference of the file whose type will be returned.
    /// - Returns: String with the type of file.
    func buildPhaseType(buildFileReference: String) -> BuildPhase? {
        if sourcesBuildPhases.contains(where: { _, val in val.files.contains(buildFileReference)}) {
            return .sources
        } else if frameworksBuildPhases.contains(where: { _, val in val.files.contains(buildFileReference)}) {
            return .frameworks
        } else if resourcesBuildPhases.contains(where: { _, val in val.files.contains(buildFileReference)}) {
            return .resources
        } else if copyFilesBuildPhases.contains(where: { _, val in val.files.contains(buildFileReference)}) {
            return .copyFiles
        } else if headersBuildPhases.contains(where: { _, val in val.files.contains(buildFileReference)}) {
            return .headers
        } else if carbonResourcesBuildPhases.contains(where: { _, val in val.files.contains(buildFileReference)}) {
            return .carbonResources
        }
        return nil
    }
    
    /// Returns the build phase type from its reference.
    ///
    /// - Parameter reference: build phase reference.
    /// - Returns: string with the build phase type.
    func buildPhaseType(buildPhaseReference: String) -> BuildPhase? {
        if sourcesBuildPhases.contains(reference: buildPhaseReference) {
            return .sources
        } else if frameworksBuildPhases.contains(reference: buildPhaseReference) {
            return .frameworks
        } else if resourcesBuildPhases.contains(reference: buildPhaseReference) {
            return .resources
        } else if copyFilesBuildPhases.contains(reference: buildPhaseReference) {
            return .copyFiles
        } else if shellScriptBuildPhases.contains(reference: buildPhaseReference) {
            return .runScript
        } else if headersBuildPhases.contains(reference: buildPhaseReference) {
            return .headers
        } else if carbonResourcesBuildPhases.contains(reference: buildPhaseReference) {
            return .carbonResources
        }
        return nil
    }
    
    /// Get the build phase name given its reference (mostly used for comments).
    ///
    /// - Parameter buildPhaseReference: build phase reference.
    /// - Returns: the build phase name.
    func buildPhaseName(buildPhaseReference: String) -> String? {
        if sourcesBuildPhases.contains(reference: buildPhaseReference) {
            return "Sources"
        } else if frameworksBuildPhases.contains(reference: buildPhaseReference) {
            return "Frameworks"
        } else if resourcesBuildPhases.contains(reference: buildPhaseReference) {
            return "Resources"
        } else if let copyFilesBuildPhase = copyFilesBuildPhases.getReference(buildPhaseReference) {
            return  copyFilesBuildPhase.name ?? "CopyFiles"
        } else if let shellScriptBuildPhase = shellScriptBuildPhases.getReference(buildPhaseReference) {
            return shellScriptBuildPhase.name ?? "ShellScript"
        } else if headersBuildPhases.contains(reference: buildPhaseReference) {
            return "Headers"
        } else if carbonResourcesBuildPhases.contains(reference: buildPhaseReference) {
            return "Rez"
        }
        return nil
    }
    
    /// Returns the build phase name a file is in (mostly used for comments).
    ///
    /// - Parameter reference: reference of the file whose type name will be returned.
    /// - Returns: the build phase name.
    func buildPhaseName(buildFileReference: String) -> String? {
        let type = buildPhaseType(buildFileReference: buildFileReference)
        switch type {
        case .copyFiles?:
            return copyFilesBuildPhases.first(where: { _, val in val.files.contains(buildFileReference)})?.value.name ?? type?.rawValue
        default:
            return type?.rawValue
        }
    }
    
    /// Returns the object with the given configuration list (project or target)
    ///
    /// - Parameter reference: configuration list reference.
    /// - Returns: target or project with the given configuration list.
    func objectWithConfigurationList(reference: String) -> PBXObject? {
        if let project = projects.first(where: { $0.value.buildConfigurationList == reference})?.value {
            return project
        }
        return nativeTargets.first(where: { $0.value.buildConfigurationList == reference})?.value
    }
    
}
