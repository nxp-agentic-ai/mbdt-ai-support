% mbdt_ai_support_path Setup Model-Based Design Toolbox AI Support

% Returns the argument which needs to be provided in the setup of the
%
% mbdt_ai_support_path('append') appends the new paths, instead of the default prepending.
% mbdt_ai_support_path('remove') removes old installation paths only.


% Copyright 2026 NXP
% 
% NXP Proprietary. This software is owned or controlled by NXP and may
% only be used strictly in accordance with the applicable license terms.
% By expressly accepting such terms or by downloading, installing,
% activating and/or otherwise using the software, you are agreeing that
% you have read, and that you agree to comply with and are bound by,
% such license terms.  If you do not agree to be bound by the applicable
% license terms, then you may not retain, install, activate or otherwise
% use the software.

function mbdt_ai_support_path(varargin)

    BOLD = [char(27) '[1m'];
    RESET = [char(27) '[0m'];
    UNDERLINE = [char(27) '[4m'];

    expandPaths = {
        'tools'
        };

    paths = {};

    oldPath = path;
    oldPathSplit = strsplit(oldPath, pathsep);

    tmpFileFullNames = which('mbdt_ai_support_path', '-all');
    if iscell(tmpFileFullNames)
        tbxRoots = cell(size(tmpFileFullNames));
        for i=1:numel(tmpFileFullNames)
            tbxRoots{i} = fileparts(tmpFileFullNames{i});
        end
    else
        tbxRoots = {fileparts(tmpFileFullNames)};
    end
    fileRoot = tbxRoots{1};

    lidx = false(size(oldPathSplit));
    for i = 1:numel(tbxRoots)
        tbxRoot = tbxRoots{i};
        for j = 1:numel(expandPaths)
            lidx = lidx | contains(oldPathSplit, fullfile(tbxRoot, expandPaths{j}), 'IgnoreCase',true);
        end

        for j = 1:numel(paths)
            lidx = lidx | strcmpi(oldPathSplit, fullfile(tbxRoot, paths{j}));
        end
    end
    newPath = strjoin(oldPathSplit(~lidx), pathsep);

    if nargin == 1 && strcmpi(varargin{1}, 'remove')
        path(newPath);
        savepath;
        rehash('toolboxcache');
        disp('Successful.');
        return;
    end

    % Add (certain) new MBD Toolbox paths
    mustFind = [expandPaths; paths];

    notFound = true(length(mustFind), 1);
    for idx = 1:length(mustFind)
        notFound(idx) = ~exist(fullfile(fileRoot, mustFind{idx}), 'dir');
    end

    if any(notFound)
        disp('Could not find a valid MBDT AI Support installation.');
        return;
    end

    %disp(['Treating ''' fileRoot ''' as MBDT AI Support installation root.']);

    rppth = [];
    for idx = 1:length(expandPaths)
        rppth = [rppth pathsep genpath(fullfile(fileRoot, expandPaths{idx}))];
    end
    for idx = 1:length(paths)
        rppth = [rppth pathsep fullfile(fileRoot, paths{idx})];
    end

    % Save, reload, done
    if nargin == 1 && strcmpi(varargin{1}, 'append')
        path([newPath pathsep rppth]);
        disp('Successful: NXP MBDT AI Support path appended.');
    else
        path([rppth pathsep newPath]);
        disp('Successful: NXP MBDT AI Support path prepended.');
    end

    savepath;
    rehash('toolboxcache');

    mcp_json_root = fullfile(fileRoot, 'tools.json');

    % provide to customer the argument for the matlab-mcp-server to
    % link the MATK Extension

    fprintf('\n%sNext step:%s Provide the following argument to %smatlab-mcp-server.exe%s: [...] --extension-file=%s\n', ...
        BOLD, RESET, BOLD, RESET, mcp_json_root);
 
end
