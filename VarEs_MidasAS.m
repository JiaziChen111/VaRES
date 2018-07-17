function [estParams,CondQ,CondES,output] = VarEs_MidasAS(y,varargin)
%VARES Summary of this function goes here
%   Detailed explanation goes here
quantileDefault = 0.05;
periodDefault = 1;
nlagDefault = 100;
callerName = 'VarEs_MidasAS';
arSpecDefault = 1;
parseObj = inputParser;
addParameter(parseObj,'Quantile',quantileDefault,@(x)validateattributes(x,{'numeric'},{'scalar','>',0,'<',1},callerName));
addParameter(parseObj,'X',[],@(x)validateattributes(x,{'numeric'},{'2d'},callerName));
addParameter(parseObj,'Period',periodDefault,@(x)validateattributes(x,{'numeric'},{'scalar','integer','positive'},callerName));
addParameter(parseObj,'NumLags',nlagDefault,@(x)validateattributes(x,{'numeric'},{'scalar','integer','positive'},callerName));
addParameter(parseObj,'Dates',[],@(x)validateattributes(x,{'numeric','cell'},{},callerName));
addParameter(parseObj,'xDates',[],@(x)validateattributes(x,{'numeric','cell'},{},callerName));
addParameter(parseObj,'Ovlap',false,@(x)validateattributes(x,{'numeric','logical'},{'binary','nonempty'},callerName));
addParameter(parseObj,'DoParallel',false,@(x)validateattributes(x,{'numeric','logical'},{'binary','nonempty'},callerName));
addParameter(parseObj,'Cores',4,@(x)validateattributes(x,{'numeric'},{'scalar','integer','positive'},callerName));
addParameter(parseObj,'numInitials',10,@(x)validateattributes(x,{'numeric'},{'scalar','integer','positive'},callerName));
addParameter(parseObj,'numInitialsRand',20000,@(x)validateattributes(x,{'numeric'},{'scalar','integer','positive'},callerName));
addParameter(parseObj,'Beta2Para',false,@(x)validateattributes(x,{'numeric','logical'},{'binary','nonempty'},callerName));
addParameter(parseObj,'GetSe',true,@(x)validateattributes(x,{'numeric','logical'},{'binary','nonempty'},callerName));
addParameter(parseObj,'Display',false,@(x)validateattributes(x,{'numeric','logical'},{'binary','nonempty'},callerName));
addParameter(parseObj,'Options',[],@(x)validateattributes(x,{},{},callerName));
addParameter(parseObj,'Params',[],@(x)validateattributes(x,{'numeric'},{'column'},callerName));
addParameter(parseObj,'Constrained',true,@(x)validateattributes(x,{'numeric','logical'},{'binary','nonempty'},callerName));
addParameter(parseObj,'startPars',[]);
addParameter(parseObj,'armaSpec',arSpecDefault);

parse(parseObj,varargin{:});
q = parseObj.Results.Quantile;
Regressor = parseObj.Results.X;
period = parseObj.Results.Period;
nlag = parseObj.Results.NumLags;
yDates = parseObj.Results.Dates;
xDates = parseObj.Results.xDates;
ovlap = parseObj.Results.Ovlap;
doparallel = parseObj.Results.DoParallel;
cores = parseObj.Results.Cores;
numInitials = parseObj.Results.numInitials;
numInitialsRand = parseObj.Results.numInitialsRand;
beta2para = parseObj.Results.Beta2Para;
options = parseObj.Results.Options;
getse = parseObj.Results.GetSe;
display = parseObj.Results.Display;
estParams = parseObj.Results.Params;
startPars = parseObj.Results.startPars;
constrained = parseObj.Results.Constrained;
arSpec  = parseObj.Results.armaSpec;

% Replace missing values by the sample average

y = y(:);
y(isnan(y)) = nanmean(y);
nobs = length(y);
% Load the conditioning variable (predictor)
if isempty(Regressor)
    Regressor = abs(y);
    if isempty(xDates)
        xDates = yDates;
    end
else
    if numel(Regressor) ~= numel(y)
        error('Conditioning variable (predictor) must be a vector of the same length as y.')
    end
    if isempty(xDates)
        error('Regressors dates need to be supplied')
    end
    Regressor = Regressor(:);
    Regressor(isnan(Regressor)) = nanmean(Regressor);
end

% Load dates
if iscell(yDates)
    yDates = datenum(yDates);    
end
if numel(yDates) ~= nobs
    error('Length of Dates must equal the number of observations.')
end

if iscell(xDates)
    xDates = datenum(xDates);    
end

if numel(xDates) ~= nobs
    error('Length of xDates must equal the number of observations.')
end

if doparallel
    currentPool = gcp('nocreate');
    if isempty(currentPool)
        parpool('local',cores);
    end
end

%%
% First get the parameter estimates of the quantile regression
if isempty(estParams)&&isempty(startPars)
    fprintf('Estimating univariate MidasQuantile... \n');
    QuantEst = MidasQuantileAS(y,'Dates',yDates,'X',Regressor','xDates',xDates,'Period',period','NumLags',nlag,...
    'Ovlap',ovlap,'GetSe',false,'Display',false,'DoParallel',doparallel,'Quantile',q,'Constrained',constrained,'Beta2Para',beta2para);
end
%%
% Prepare data for the LHS and RHS of the quantile regression
% LHS: n-period returns by aggregating y(t),...,y(t+period-1)
% RHS: many lagged returns by extracting y(t-1),...,y(t-nlag)
MixedRet = MixedFreqQuantile(y,yDates,y,yDates,nlag,period,ovlap);
yHighOri = MixedRet.EstX;

MixedData = MixedFreqQuantile(y,yDates,Regressor,xDates,nlag,period,ovlap);
yLowFreq = MixedData.EstY;
xHighFreq = MixedData.EstX;
yDates = MixedData.EstYdate;
xDates = MixedData.EstXdate;
nobsEst = size(yLowFreq,1);

% Estimating the Conditional Mean
constant = 1; 
if isempty(estParams)
    if isempty(startPars)
        [meanEst,~,~,~,~,meanOutput] = armaxfilter(yLowFreq,constant,arSpec,0);
    else
        [meanEst,~,~,~,~,meanOutput] =  armaxfilter(yLowFreq,constant,arSpec,0,[],startPars(1:sum(arSpec)));
    end
    mu = yLowFreq - armaxerrors([meanEst;0],1:arSpec,0,constant,yLowFreq,[],arSpec,ones(size(yLowFreq)));
    mu(1:arSpec) = repmat(mean(yLowFreq),arSpec,1);
end
%%
% In case of known parameters, just compute conditional quantile/ES and exit.
if ~isempty(estParams)
    meanEst = estParams(1:sum(armaSpec));
    if constant == 0
    meanPars = [0;meanEst];
    else
    meanPars = meanEst;
    end
    if ar == 0 
    meanPars = [meanPars(1);0;meanPars(2:end)];
    end
    if ma == 0 
    meanPars = [meanPars;0];
    end
    varPars = estParams(sum(armaSpec)+1:end);
    mu = yLowFreq - armaxerrors(meanPars,arEst,maEst,constant,yLowFreq,[],m,ones(size(yLowFreq)));
    mu(1) = mean(yLowFreq);
    [~,CondQ,CondES] = ALdist2(varPars,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para);
    Hit = q - (yLowFreq <= CondQ);
    HitPercentage    = mean(Hit(1:nobsEst) + q) * 100;
    if nargout > 3
    output.estParams = estParams;
    output.quantile = q;
    output.y = yLowFreq ;
    output.Hit = Hit;
    output.HitPercentage = HitPercentage;
    output.VaR = CondQ;
    output.ES = CondES;
    output.Dates = yDates;
    end
    return
end
%%
% Get the initial parameters for the AL distribution
if isempty(startPars)
    fprintf('Finding the initial Betas for VaREs... \n');
    betaIni = IniParAL2(mu,QuantEst,yLowFreq,yHighOri,xHighFreq,q,beta2para,numInitialsRand,numInitials,doparallel);
else
    betaIni = startPars(arSpec+2:end)';
end
% Bounds for numerical optimization in case use fmincon
fprintf('Optimizing parameters.... \n');
tol = 1e-8;
if ~beta2para
lb = [-Inf;-Inf;-Inf;1+tol;-Inf];
ub = [Inf;Inf;Inf;200-tol;0-tol];
else
lb = [-Inf;-Inf;-Inf;1+tol;1+tol;-Inf];
ub = [Inf;Inf;Inf;200-tol;200-tol;Inf];
end

% Optimization options
MaxFunEvals = 3000; 
MaxIter = 3000;

if isempty(options)
   options = optimset('Display','off','MaxFunEvals',MaxFunEvals,'MaxIter',MaxIter, 'TolFun', 1e-8, 'TolX', 1e-8);
end

optionsUnc = optimoptions(@fminunc,'Display','off','Algorithm','quasi-newton',...
    'MaxFunEvals',MaxFunEvals,'MaxIter',MaxIter);

REP = 15;
% Numeric minimization
estParams = zeros(size(betaIni));
fval = zeros(size(betaIni,1),1);
exitFlag = zeros(size(betaIni,1),1);
if doparallel
parfor i = 1:size(betaIni,1)  
    %if exist('patternsearch','file') ~= 0
    %    [estParams(i,:),fval(i,1),exitFlag(i,1)] = patternsearch(@(params) ALdist2(params,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para),betaIni(i,:),[],[],[],[],lb,ub,options);        
    %else
   [estParams(i,:),fval(i,1),exitFlag(i,1)] = fminsearch(@(params) ALdist2(params,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para),betaIni(i,:));
   for ii = 1:REP
     try
      [estParams(i,:),fval(i,1),exitFlag(i,1)]  = fminunc(@(params) ALdist2(params,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para),estParams(i,:),optionsUnc);
     catch
       warning('fminunc does work. Move on to the fminsearch.');
     end
     [estParams(i,:),fval(i,1),exitFlag(i,1)]  = fminsearch(@(params) ALdist2(params,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para),estParams(i,:),options);
     if constrained
     [estParams(i,:),fval(i,1),exitFlag(i,1)]  = fminsearchbnd(@(params) ALdist2(params,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para),estParams(i,:),lb,ub,options); 
     end
       if exitFlag(i,1) == 1
           break
       end
    end
    %end
end
else
for i = 1:size(betaIni,1)  
    %if exist('patternsearch','file') ~= 0
    %    [estParams(i,:),fval(i,1),exitFlag(i,1)] = patternsearch(@(params) ALdist2(params,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para),betaIni(i,:),[],[],[],[],lb,ub,options);        
    %else
   [estParams(i,:),fval(i,1),exitFlag(i,1)] = fminsearch(@(params) ALdist2(params,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para),betaIni(i,:));
   for ii = 1:REP
     try
      [estParams(i,:),fval(i,1),exitFlag(i,1)]  = fminunc(@(params) ALdist2(params,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para),estParams(i,:),optionsUnc);
     catch
       warning('fminunc does work. Move on to the fminsearch.');
     end
     [estParams(i,:),fval(i,1),exitFlag(i,1)]  = fminsearch(@(params) ALdist2(params,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para),estParams(i,:),options);
     if constrained
     [estParams(i,:),fval(i,1),exitFlag(i,1)]  = fminsearchbnd(@(params) ALdist2(params,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para),estParams(i,:),lb,ub,options); 
     end
       if exitFlag(i,1) == 1
           break
       end
    end
    %end
end   
end
SortedFval = sortrows([fval,exitFlag,estParams],1);
estParams = SortedFval(1,3:size(SortedFval,2))';
fval = SortedFval(1,1); 
exitFlag = SortedFval(1,2);
[~,CondQ,CondES,LLH] = ALdist2(estParams,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para);
%%
%Get standard errors using the simulation approach
if getse
fprintf('Getting standard errors... \n');
nsim = 200;
resid = (yLowFreq - CondQ)./abs(CondQ);
paramSim = zeros(length(estParams),nsim);
if doparallel
parfor r = 1:nsim
    ind = randi(nobsEst,[nobsEst,1]);
    residSim = resid(ind);
    %xHighFreqSim = xHighFreq(ind,:);
    %yHighOriSim = yHighOri(ind,:);
    [yLowFreqSim,muSim] = GetSim(estParams,meanEst,arSpec,yHighOri,xHighFreq,beta2para,residSim);
    paramSim(:,r) = fminsearch(@(params) ALdist2(params,muSim,yLowFreqSim,yHighOri,xHighFreq,q,beta2para),estParams,options);
end
else
for r = 1:nsim
    ind = randi(nobsEst,[nobsEst,1]);
    residSim = resid(ind);
    %xHighFreqSim = xHighFreq(ind,:);
    %yHighOriSim = yHighOri(ind,:);
    [yLowFreqSim,muSim] = GetSim(estParams,meanEst,arSpec,yHighOri,xHighFreq,beta2para,residSim);
    paramSim(:,r) = fminsearch(@(params) ALdist2(params,muSim,yLowFreqSim,yHighOri,xHighFreq,q,beta2para),estParams,options);
end
end
se = std(paramSim,0,2);
if beta2para
    hypothesis = [0;0;0;1;1;0];
else
    hypothesis = [0;0;0;1;0];
end
% Hypothesis that the betaLags is not equal to 1, which mean equally
% weighted (i.e., no point of using MIDAS lags);
meanParamSim = repmat(mean(paramSim,2),1,nsim);
pval =  mean(abs(paramSim - meanParamSim + hypothesis) > repmat(abs(estParams),1,nsim),2);
else
se = nan(length(estParams),1); 
pval = nan(length(estParams),1);
zstat = nan(length(estParams),1);
end
meanSe = meanOutput.CoefStdErr;
meanPval = meanOutput.CoefPval;
estParams = [meanEst;estParams];
se = [meanSe;se];
pval = [meanPval;pval];
%%
% Get all estimation table
columnNames = {'Coeff','StdErr','Prob'};
    TableEst = table(estParams,se,pval,'VariableNames',columnNames);
if display
    if exist('patternsearch','file') ~= 0        
        fprintf('Method: Asymmetric loss function minimization, Pattern search\n');
    else        
        fprintf('Method: Asymmetric loss function minimization, Nelder-Mead search\n');
    end
    fprintf('Sample size:                 %d\n',nobs);
    fprintf('Adjusted sample size:        %d\n',nobsEst);
    fprintf('Minimized function value: %10.6g\n',fval);
    disp(TableEst);
end
%%
% Get the output file
Hit = q - (yLowFreq <= CondQ);
HitPercentage    = mean(Hit(1:nobsEst) + q) * 100;
if nargout > 3
output.estParams = estParams;
output.CondQ = CondQ;
output.CondES = CondES;
output.fval = fval;
output.se = se; 
output.pval = pval;
output.exitFlag = exitFlag;
output.Hit = Hit;
output.HitPercentage = HitPercentage;
output.nobs = nobsEst;
output.TableEst = TableEst;
output.yLowFreq = yLowFreq;
output.nlag = nlag;
output.xHighFreq = xHighFreq;
output.quantile = q; 
output.beta2para = beta2para;
output.horizon = period;
output.Dates = yDates; 
output.xDates = xDates;
output.LLH = LLH;
if beta2para
output.weights = estParams(2) * midasBetaWeights(nlag,estParams(4),estParams(5));
else
output.weights = estParams(2) * midasBetaWeights(nlag,1,estParams(4));
end
if isempty(startPars)
output.QuantEst = QuantEst;
end
end
end

%%
% Local Function
%-------------------------------------------------------
% Local function for the beta polynomial
function weights = midasBetaWeights(nlag,param1,param2)
seq = linspace(eps,1-eps,nlag);
if param1 == 1    
    weights = (1-seq).^(param2-1);    
else
    weights = (1-seq).^(param2-1) .* seq.^(param1-1);    
end
weights = weights ./ nansum(weights);
end
%----------------------------------------------------------------------
% Function to mix the data
function Output = MixedFreqQuantile(DataY,DataYdate,DataX,DataXdate,xlag,period,Ovlap)

nobs = size(DataY,1); 
nobsShort = nobs-xlag-period+1;
DataYlowfreq = zeros(nobsShort,1);
DataYDateLow = zeros(nobsShort,1);
for t = xlag+1 : nobs-period+1
    DataYlowfreq(t-xlag,1) = sum(DataY(t:t+period-1));
    DataYDateLow(t-xlag,1) = DataYdate(t);
end
if ~Ovlap
    DataYlowfreq = DataYlowfreq(1:period:end,:);
    DataYDateLow = DataYDateLow(1:period:end,:);
end
% Set the start date and end date according to xlag, period and ylag
minDateY = DataYDateLow(1);
minDateX = DataXdate(xlag+1);
if minDateY > minDateX
    estStart = minDateY;
else
    estStart = minDateX;
end
maxDateY = DataYDateLow(end);
maxDateX = DataXdate(end);
if maxDateY > maxDateX
    estEnd = maxDateX;
else
    estEnd = maxDateY;
end

% Construct Y data
tol = 1e-10;
locStart = find(DataYDateLow >= estStart-tol, 1);
locEnd = find(DataYDateLow >= estEnd-tol, 1);
EstY = DataYlowfreq(locStart:locEnd);
EstYdate = DataYDateLow(locStart:locEnd);

nobsEst = size(EstY,1);
% Construct lagged X data
EstX = zeros(nobsEst,xlag);
EstXdate = zeros(nobsEst,xlag);
for t = 1:nobsEst
    loc = find(DataXdate >= EstYdate(t)-tol, 1);
    if isempty(loc)
        loc = length(DataXdate);
    end
    
    if loc > size(DataX,1)        
        nobsEst = t - 1;
        EstY = EstY(1:nobsEst,:);
        EstYdate = EstYdate(1:nobsEst,:);
        EstX = EstX(1:nobsEst,:);
        EstXdate = EstXdate(1:nobsEst,:);
        maxDate = EstYdate(end);
        warning('MixFreqData:EstEndOutOfBound',...
            'Horizon is a large negative number. Observations are further truncated to %s',datestr(maxDate))
        break
    else        
        EstX(t,:) = DataX(loc-1:-1:loc-xlag);
        EstXdate(t,:) = DataXdate(loc-1:-1:loc-xlag);
    end    
end

Output = struct('EstY',EstY,'EstYdate',EstYdate,'EstX',EstX,'EstXdate',EstXdate,...
    'EstStart',estStart,'EstEnd',estEnd);
end
%------------------------------------------------------------------------
% function to get initial estimation of the beta
function beta = IniParAL2(mu,QuantEst,yLowFreq,yHighOri,xHighFreq,q,beta2para,numInitialsRand,numInitials,doparallel)
% Randomly sample second parameter of Beta polynomial
nInitalALbeta = unifrnd(-3,0,[numInitialsRand,1]);
InitialParamsVec = [repmat(QuantEst',numInitialsRand,1),nInitalALbeta];
RQfval = zeros(numInitialsRand,1);
if doparallel
parfor i = 1:numInitialsRand
    RQfval(i) = ALdist2(InitialParamsVec(i,:),mu,yLowFreq,yHighOri,xHighFreq,q,beta2para);
end
else
for i = 1:numInitialsRand
    RQfval(i) = ALdist2(InitialParamsVec(i,:),mu,yLowFreq,yHighOri,xHighFreq,q,beta2para);
end
end
Results = [RQfval,InitialParamsVec];
SortedResults = sortrows(Results,1);
beta = SortedResults(1:numInitials,2:size(SortedResults,2));
end

%------------------------------------------------------------------------
% function to retrun the -loglikehood of AL dist and condQ and ES
function [llh,condQ,es,LLH] = ALdist2(params,mu,yLowFreq,yHighOri,xHighFreq,q,beta2para)
intercept = params(1);
slope1 = params(2);
slope2 = params(3);
if beta2para
k1 = params(4);
k2 = params(5);
phi = params(6);
else
k1 = 1;
k2 = params(4);
phi = params(5);
end
% Compute MIDAS weights
nlag = size(xHighFreq,2);
weights = midasBetaWeights(nlag,k1,k2)';
%nobs = length(yLowFreq);
%condQ = zeros(nobs,1);
% Conditional quantile
%for t = 1:nobs
X_neg = xHighFreq .* (yHighOri<=0);
X_pos = xHighFreq .* (yHighOri>0);
condQ = intercept + slope1 .* (X_pos * weights) + slope2 .* (X_neg * weights);
%end
es = (1 + exp(phi)).*condQ;
hit = q - (yLowFreq<=condQ);
%muAdj = mu - es;
%ALdistLog = log(((1-q)./muAdj).*exp(((condQ - yLowFreq).*hit)./(q.*muAdj)));
ALdist = ((1-q)./(mu - es)).*exp(((condQ-yLowFreq).*hit)./(q.*(mu-es)));
%ALdist(ALdist < 0) = 1e100;
ALdistLog = log(ALdist);
ALdistLog(~isreal(ALdistLog)) = -1e100;
llh = -1*sum(ALdistLog)/length(ALdistLog);
LLH = ALdistLog;
end

%-------------------------------------------------------------------------
% Local function: Compute the yLowFreqSim

function [yLowFreqSim,muSim] = GetSim(params,meanEst,arSpec,yHighOriSim,xHighFreqSim,beta2para,ResidSim)
% Allocate the parameters
intercept = params(1);
slope1 = params(2);
slope2 = params(3);
if beta2para
k1 = params(4);
k2 = params(5);
phi = params(6);
else
k1 = 1;
k2 = params(4);
phi = params(5);
end
% Compute MIDAS weights
nlag = size(xHighFreqSim,2);
weights = midasBetaWeights(nlag,k1,k2)';
%nobs = size(xHighFreqSim,1);
%CondQsim = zeros(nobs,1);
% Conditional quantile
%for t = 1:nobs
X_neg = (yHighOriSim<=0);
X_pos = (yHighOriSim>0);
CondQsim = intercept + slope1 .* ((xHighFreqSim.* X_pos) * weights) + slope2 .* ((xHighFreqSim .* X_neg) * weights);
%end
CondESsim = (1+exp(phi)).*CondQsim; 
yLowFreqSim = CondQsim + abs(CondQsim).*ResidSim;
Exceed = find(yLowFreqSim <= CondQsim);
ESsimMean = mean(ResidSim(ResidSim<0));
yLowFreqSim(Exceed,:) = CondQsim(Exceed) + (1/ESsimMean).*ResidSim(Exceed).*(CondESsim(Exceed)-CondQsim(Exceed));
muSim = repmat(meanEst(1),size(yLowFreqSim,1),1); 
if arSpec > 0 
for i = (arSpec+1):size(yLowFreqSim,1)
    muSim(i) = muSim(i) + meanEst(2:end).*yLowFreqSim(i-1:-1:i-arSpec);
end
end
end