function [data,destroy]=rpdw(data,ref1,offset1,ref2,offset2,fill,filler,trim)
%RPDW    Read partial data window from binary seismic datafiles
%
%    Description: Reads a partial data window from a binary seismic 
%     datafile using the reference and offset parameters given.  This 
%     provides a mechanism similar to the SAC 'cut' command to limit memory 
%     usage.  Input parameters are exactly the same as the seislab 'cutim'
%     command - for details on cutting read there.
%
%    Usage: [data]=rpdw(data,ref1,offset1,ref2,offset2,fill,filler,trim)
%
%    See also: cutim, rh, rdata, rseis, wh, wseis

% input check
error(nargchk(1,8,nargin))

% check data structure
error(seischk(data,'name','endian'))

% defaults
if(nargin<8); trim=true; end
if(nargin<7); filler=0; end
if(nargin<6); fill=0; end
if(nargin<5); offset2=0; end
if(nargin<4); ref2='e'; end
if(nargin<3); offset1=0; end
if(nargin<2); ref1='b'; end

% empty cut parameter defaults
if(isempty(ref1)); if(isempty(offset1)); ref1='b'; else ref1='z'; end; end
if(isempty(ref2)); if(isempty(offset2)); ref2='e'; else ref2='z'; end; end
if(isempty(offset1)); offset1=0; end
if(isempty(offset2)); offset2=0; end
if(isempty(fill)); fill=0; end
if(isempty(filler)); filler=0; end
if(isempty(trim)); trim=true; end

% number of seismograms
nrecs=length(data);

% cut parameter checks
if(~ischar(ref1) || ~ischar(ref2))
    error('seislab:rpdw:badInput','ref must be a string')
elseif(~isnumeric(offset1) || ~isnumeric(offset2) || ...
        ~isvector(offset1) || ~isvector(offset2))
    error('seislab:rpdw:badInput','offset must be a numeric vector')
elseif(~any(length(offset1)==[1 nrecs]) || ...
        ~any(length(offset2)==[1 nrecs]))
    error('seislab:rpdw:badInputSize','offset dimensions not correct')
end

% grab header info
iftype=genumdesc(data,'iftype');
leven=glgc(data,'leven');
warning('off','seislab:gh:fieldInvalid')
[b,npts,delta,ncmp]=gh(data,'b','npts','delta','ncmp');
warning('on','seislab:gh:fieldInvalid')

% clean up and check ncmp
ncmp(isnan(ncmp))=1;
if(any(ncmp<1 | fix(ncmp)~=ncmp))
    error('seislab:rpdw:badNumCmp',...
        'field ncmp must be a positive integer')
end

% check leven
t=strcmp(leven,'true');
f=strcmp(leven,'false');
ti=find(t);
fi=find(f);
if(~all(t | f))
    error('sieslab:rpdw:levenBad',...
        'logical field leven needs to be set'); 
end

% expand scalar offsets
if(length(offset1)==1)
    offset1=offset1(ones(nrecs,1));
end
if(length(offset2)==1)
    offset2=offset2(ones(nrecs,1));
end

% window begin point
if(strcmpi(ref1,'z'))
    bt(1:nrecs,1)=offset1;
elseif(strcmpi(ref1,'n'))
    bp=round(offset1);
else
    bt=gh(data,ref1)+offset1;
end

% window end time
if(strcmpi(ref2,'z'))
    et(1:nrecs,1)=offset2;
elseif(strcmpi(ref2,'n') || strcmpi(ref2,'l'))
    ep=round(offset2);
else
    et=gh(data,ref2)+offset2;
end

% grab header setup
vers=unique([data.version]);
nver=length(vers);
h(nver)=seishi(vers(nver));
for i=1:nver-1
    h(i)=seishi(vers(i));
end

% allocate bad records matrix
destroy=false(nrecs,1);

% let rdata/cutim handle unevenly sampled records minus file deletion
if(~isempty(fi))
    [data(fi),destroy(fi)]=rdata(data(fi),false);
    if(~isempty(fi(~destroy(fi))))
        [data(fi(~destroy(fi))),destroy(fi(~destroy(fi)))]=...
            cutim(data(fi(~destroy(fi))),ref1,offset1,ref2,offset2,...
            fill,filler,false);
    end
end

% loop through each file
for i=ti.'
    % header version index
    v=(data(i).version==vers);
    
    % check for unsupported filetypes
    if(strcmp(iftype(i),'General XYZ (3-D) file'))
        destroy(i)=true;
        warning('seislab:cutim:illegalFiletype',...
            'illegal operation on xyz file');
        continue;
    elseif(any(strcmp(iftype(i),{'Spectral File-Real/Imag'...
            'Spectral File-Ampl/Phase'})))
        destroy(i)=true;
        warning('seislab:cutim:illegalFiletype',...
            'illegal operation on spectral file');
        continue;
    end
    
    % closest points to begin and end
    if(~strcmpi(ref1,'n'))
        bp(i)=round((bt(i)-b(i))/delta(i))+1;
    end
    if(strcmpi(ref2,'l'))
        ep2=bp(i)+ep(i)-1;
    elseif(strcmpi(ref2,'n'))
        ep2=ep(i);
    else
        ep2=round((et(i)-b(i))/delta(i))+1;
    end
    
    % boundary conditions
    nbp=max([bp(i) 1]);
    nep=min([ep2 npts(i)]);
    nnp=nep-nbp+1;
    
    % open file
    fid=fopen(data(i).name,'r',data(i).endian);
    
    % check that it opened
    if(fid<0)
        warning('seislab:rpdw:badFID',...
            'File not openable, %s',data(i).name);
        destroy(i)=true;
        continue;
    end
    
    % preallocate data record with NaNs, deallocate timing
    data(i).x=nan(nnp,ncmp(i),h(v).data.store);
    data(i).t=[];
    
    % skip if new npts==0
    if(nnp<1)
        data(i)=ch(data(i),'b',0,'e',0,'npts',0,'delta',0,...
            'depmen',0,'depmin',0,'depmax',0);
        destroy(i)=true;
        continue;
    end
    
    % loop through each component
    for j=1:ncmp(i)
        % move to first byte of window and read
        try
            fseek(fid,h(v).data.startbyte+...
                h(v).data.bytesize*((j-1)*npts(i)+nbp-1),'bof');
            data(i).x(:,j)=fread(fid,nnp,['*' h(v).data.store]);
        catch
            warning('seislab:rpdw:readFailed',...
                'Read in of data failed: %s',data(i).name);
            destroy(i)=true;
            break;
        end
    end
    
    % close file
    fclose(fid);
    
    % skip to next if read failed
    if(destroy(i)); continue; end
    
    % fill or no
    if(fill)
        % add filler
        data(i).x=[ones(1-bp(i),ncmp(i))*filler; ...
            data(i).x; ...
            ones(ep2-npts(i),ncmp(i))*filler];
        
        % empty window - add to destroy list
        if(isempty(data(i).x))
            data(i)=ch(data(i),'b',0,'e',0,'npts',0,'delta',0,...
                'depmen',0,'depmin',0,'depmax',0);
            destroy(i)=true;
            continue;
        end
        
        % fix header
        data(i)=ch(data(i),'b',b(i)+(bp(i)-1)*delta(i),...
            'e',b(i)+(ep2-1)*delta(i),'npts',size(data(i).x,1),...
            'depmen',norm(mean(data(i).x)),...
            'depmin',-norm(min(data(i).x)),...
            'depmax',norm(max(data(i).x)));
    else
        % empty window - add to destroy list
        if(isempty(data(i).x))
            data(i)=ch(data(i),'b',0,'e',0,'npts',0,'delta',0,...
                'depmen',0,'depmin',0,'depmax',0);
            destroy(i)=true;
            continue;
        end
        
        % fix header
        data(i)=ch(data(i),'b',b(i)+(nbp-1)*delta(i),...
            'e',b(i)+(nep-1)*delta(i),'npts',size(data(i).x,1),...
            'depmen',norm(mean(data(i).x)),...
            'depmin',-norm(min(data(i).x)),...
            'depmax',norm(max(data(i).x)));
    end
end

% destroy empty records
if(trim); data(destroy)=[]; end

end
