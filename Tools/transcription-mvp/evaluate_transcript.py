"""Word-error measurement independent of capitalization and punctuation."""
import argparse,json,re
from pathlib import Path

def tokens(text): return re.findall(r"[a-z0-9]+(?:'[a-z]+)?",text.lower())

def compare(reference,hypothesis):
    a,b=tokens(reference),tokens(hypothesis)
    dp=[[0]*(len(b)+1) for _ in range(len(a)+1)]
    for i in range(len(a)+1):dp[i][0]=i
    for j in range(len(b)+1):dp[0][j]=j
    for i in range(1,len(a)+1):
        for j in range(1,len(b)+1):dp[i][j]=min(dp[i-1][j]+1,dp[i][j-1]+1,dp[i-1][j-1]+(a[i-1]!=b[j-1]))
    i,j=len(a),len(b);counts={'substitutions':0,'deletions':0,'insertions':0};changes=[]
    while i or j:
        if i and j and dp[i][j]==dp[i-1][j-1]+(a[i-1]!=b[j-1]):
            if a[i-1]!=b[j-1]:counts['substitutions']+=1;changes.append({'reference':a[i-1],'hypothesis':b[j-1]})
            i-=1;j-=1
        elif i and dp[i][j]==dp[i-1][j]+1:counts['deletions']+=1;changes.append({'reference':a[i-1],'hypothesis':None});i-=1
        else:counts['insertions']+=1;changes.append({'reference':None,'hypothesis':b[j-1]});j-=1
    return {'reference_words':len(a),'hypothesis_words':len(b),**counts,'word_error_rate':dp[-1][-1]/len(a) if a else None,'changes':list(reversed(changes))}

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('reference',type=Path);parser.add_argument('hypothesis',type=Path);args=parser.parse_args()
    print(json.dumps(compare(args.reference.read_text(encoding='utf-8'),args.hypothesis.read_text(encoding='utf-8')),ensure_ascii=False,indent=2))
